"""Small Dependency-Track 4.x REST client shared by the collector and
ops/dtrack_admin.py. Endpoints checked against the 4.14.6 source."""
import requests

# One Dependency-Track team per org, named after the org's Entra group so the
# OIDC group mapping and the team line up (N2).
ORG_TEAM = "sg-sbom-org-{org}"
# Teams whose API keys upload BOMs under the org parents: the collector, and
# sbom-scan.yml for the Terraform/npm SBOMs that CI still builds.
UPLOADER_TEAMS = ("bom-uploader", "ci-uploader")


class DependencyTrack:
    def __init__(self, base_url, api_key, timeout=30):
        self.base, self.timeout = base_url.rstrip("/"), timeout
        self.session = requests.Session()
        self.session.headers["X-Api-Key"] = api_key

    def call(self, method, path, ok=(), **kw):
        """Request /api/v1/<path>; raises on HTTP errors except those in ok."""
        r = self.session.request(method, f"{self.base}/api/v1/{path}", timeout=kw.pop("timeout", self.timeout), **kw)
        if r.status_code not in ok:
            r.raise_for_status()
        return r

    def paged(self, path, params=None, size=100):
        page = 1
        while True:
            r = self.call("GET", path, params={**(params or {}), "pageNumber": page, "pageSize": size})
            items = r.json()
            yield from items
            if not items or page * size >= int(r.headers.get("X-Total-Count", 0)):
                return
            page += 1

    # ---------- projects ----------
    def find_project(self, name, version=None):
        for p in self.call("GET", "project", params={"name": name, "excludeInactive": "true"}).json():
            if p["name"] == name and (p.get("version") or None) == version:
                return p
        return None

    def ensure_parent(self, org):
        """UUID of the org's parent collection project, created if missing.
        With portfolio access control on, the caller's team must already be on
        the parent's ACL to see it — sync_acl and onboard-org make sure of that."""
        for _ in range(2):
            p = self.find_project(org)
            if p:
                return p["uuid"]
            r = self.call("PUT", "project", ok=(409,),
                          json={"name": org, "classifier": "APPLICATION", "active": True,
                                "collectionLogic": "AGGREGATE_DIRECT_CHILDREN"})
            if r.status_code != 409:  # 409: someone else created it first; look again
                return r.json()["uuid"]
        raise RuntimeError(f"Dependency-Track parent project {org} exists but is not visible to this API key "
                           "(portfolio access control): add the key's team to the parent's ACL")

    def upload_bom(self, name, version, parent_uuid, bom_b64):
        self.call("PUT", "bom", timeout=120,
                  json={"projectName": name, "projectVersion": version, "autoCreate": True,
                        "parentUUID": parent_uuid, "bom": bom_b64})

    def org_parents(self):
        """Root collection projects with no version — the per-org parents."""
        for p in self.paged("project", {"onlyRoot": "true", "excludeInactive": "true"}):
            if not p.get("version") and p.get("collectionLogic", "NONE") != "NONE":
                yield p

    # ---------- teams and access control ----------
    def teams(self):
        return {t["name"]: t for t in self.call("GET", "team").json()}

    def grant(self, team_uuid, project_uuid):
        """Put a team on a project's ACL. True if newly added, False if already there."""
        r = self.call("PUT", "acl/mapping", ok=(409,), json={"team": team_uuid, "project": project_uuid})
        return r.status_code != 409

    def sync_acl(self):
        """Portfolio access control in Dependency-Track 4.x is per project: a
        team on the parent's ACL does NOT see the children, and auto-created
        projects only get the uploading key's team. So every child of an org
        parent needs that org's team explicitly. Needs ACCESS_MANAGEMENT.
        Returns (new mappings, orgs skipped because their team is missing)."""
        teams, granted, missing = self.teams(), 0, []
        uploaders = [teams[n] for n in UPLOADER_TEAMS if n in teams]
        for parent in self.org_parents():
            org_team = teams.get(ORG_TEAM.format(org=parent["name"]))
            if not org_team:
                missing.append(parent["name"])
                continue
            for team in [org_team, *uploaders]:
                granted += self.grant(team["uuid"], parent["uuid"])
            for child in self.paged(f"project/{parent['uuid']}/children"):
                granted += self.grant(org_team["uuid"], child["uuid"])
        return granted, missing
