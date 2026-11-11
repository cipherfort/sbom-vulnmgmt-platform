"""Small Dependency-Track 4.x REST client shared by the collector and
ops/dtrack_admin.py. Endpoints checked against the 4.14.6 source."""
import requests


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

    # ---------- projects ----------
    def find_project(self, name, version=None):
        for p in self.call("GET", "project", params={"name": name, "excludeInactive": "true"}).json():
            if p["name"] == name and (p.get("version") or None) == version:
                return p
        return None

    def ensure_parent(self, org):
        """UUID of the org's parent collection project, created if missing."""
        for _ in range(2):
            p = self.find_project(org)
            if p:
                return p["uuid"]
            r = self.call("PUT", "project", ok=(409,),
                          json={"name": org, "classifier": "APPLICATION", "active": True,
                                "collectionLogic": "AGGREGATE_DIRECT_CHILDREN"})
            if r.status_code != 409:  # 409: someone else created it first; look again
                return r.json()["uuid"]
        raise RuntimeError(f"Dependency-Track parent project {org} exists but is not visible to this API key: "
                           "portfolio access control is on, so turn it off or put the key's team on the parent's ACL")

    def upload_bom(self, name, version, parent_uuid, bom_b64):
        self.call("PUT", "bom", timeout=120,
                  json={"projectName": name, "projectVersion": version, "autoCreate": True,
                        "parentUUID": parent_uuid, "bom": bom_b64})

    # ---------- teams ----------
    def teams(self):
        return {t["name"]: t for t in self.call("GET", "team").json()}
