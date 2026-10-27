"""One-off and per-org Dependency-Track setup, run by CPS from a machine that
can reach the internal Dependency-Track API. Idempotent: safe to re-run.

  export DTRACK_URL=https://ca-dtrack-api.<env-domain>
  export DTRACK_ADMIN_API_KEY=...  # team with ACCESS_MANAGEMENT, SYSTEM_CONFIGURATION, POLICY_MANAGEMENT
  export GITHUB_ADVISORIES_TOKEN=...       # read-only GitHub token for the GitHub Advisories mirror (bootstrap only)

  python ops/dtrack_admin.py bootstrap --key-vault-url https://kv-sbom-prd.vault.azure.net/
  python ops/dtrack_admin.py onboard-org cps --teams-webhook https://...
  python ops/dtrack_admin.py sync-acl

See docs/enterprise-sbom/delivery-plan.md (Phase 1 step 4, Phase 2) and
docs/how-to-use.md ("Onboarding an org").
"""
import argparse
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from dtrack import ORG_TEAM, UPLOADER_TEAMS, DependencyTrack  # noqa: E402

CPS_ADMINS = "sg-sbom-cps-admins"

# Team -> permissions. ACCESS_MANAGEMENT also bypasses portfolio access
# control in Dependency-Track 4.x, which is how CPS "sees everything" (N2).
TEAMS = {
    "bom-uploader": ["BOM_UPLOAD", "PROJECT_CREATION_UPLOAD", "VIEW_PORTFOLIO", "PORTFOLIO_MANAGEMENT"],
    "ci-uploader": ["BOM_UPLOAD", "PROJECT_CREATION_UPLOAD", "VIEW_PORTFOLIO"],
    "acl-sync": ["ACCESS_MANAGEMENT", "VIEW_PORTFOLIO"],
    CPS_ADMINS: ["ACCESS_MANAGEMENT", "VIEW_PORTFOLIO", "PORTFOLIO_MANAGEMENT", "VIEW_VULNERABILITY",
                 "VULNERABILITY_ANALYSIS", "VULNERABILITY_MANAGEMENT", "VIEW_POLICY_VIOLATION",
                 "POLICY_VIOLATION_ANALYSIS", "POLICY_MANAGEMENT", "SYSTEM_CONFIGURATION"],
}
ORG_TEAM_PERMISSIONS = ["VIEW_PORTFOLIO", "VIEW_VULNERABILITY", "VULNERABILITY_ANALYSIS",
                        "VIEW_POLICY_VIOLATION", "POLICY_VIOLATION_ANALYSIS"]
# Team -> Key Vault secret its generated API key goes to. The collector reads
# the first two; ci-uploader's key is copied to GitHub as the
# DEPENDENCY_TRACK_API_KEY secret for sbom-scan.yml.
KEY_SECRETS = {"bom-uploader": "dtrack-api-key", "acl-sync": "dtrack-acl-key", "ci-uploader": "dtrack-ci-api-key"}

OSV_ECOSYSTEMS = ["npm", "PyPI", "Maven", "Go", "NuGet", "RubyGems", "crates.io", "Packagist", "Pub", "Hex",
                  "GitHub Actions", "SwiftURL"]
RESTRICTED_LICENCES = ["AGPL-1.0-only", "AGPL-1.0-or-later", "AGPL-3.0-only", "AGPL-3.0-or-later", "SSPL-1.0"]

# Starter policies from the design doc, all warn/info for the first 3 months.
POLICIES = [
    {"name": "Critical or high vulnerability", "violationState": "WARN",
     "conditions": [{"subject": "SEVERITY", "operator": "IS", "value": "CRITICAL"},
                    {"subject": "SEVERITY", "operator": "IS", "value": "HIGH"}]},
    # Only applies to projects tagged "distributed" (services shipped outside CPS).
    {"name": "Restricted or unknown licence in distributed service", "violationState": "WARN",
     "tags": ["distributed"],
     "conditions": [{"subject": "LICENSE_GROUP", "operator": "IS", "value": "@restricted-group"},
                    {"subject": "LICENSE", "operator": "IS", "value": "unresolved"}]},
    {"name": "Component 3+ major versions behind", "violationState": "INFO",
     "conditions": [{"subject": "VERSION_DISTANCE", "operator": "NUMERIC_GREATER_THAN_OR_EQUAL",
                     "value": json.dumps({"epoch": "0", "major": "3", "minor": "?", "patch": "?"})}]},
]


def ensure_team(dt, name, permissions):
    team = dt.teams().get(name) or dt.call("PUT", "team", json={"name": name}).json()
    for perm in permissions:
        dt.call("POST", f"permission/{perm}/team/{team['uuid']}", ok=(304,))
    return team


def ensure_oidc_mapping(dt, group_name, team_uuid):
    groups = {g["name"]: g for g in dt.call("GET", "oidc/group").json()}
    group = groups.get(group_name) or dt.call("PUT", "oidc/group", json={"name": group_name}).json()
    dt.call("PUT", "oidc/mapping", ok=(409,), json={"team": team_uuid, "group": group["uuid"]})


def store_key(team_name, key, key_vault_url):
    secret = KEY_SECRETS[team_name]
    if not key_vault_url:
        print(f"{team_name} API key (store as Key Vault secret {secret}; shown once): {key}", file=sys.stderr)
        return
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient
    SecretClient(key_vault_url, DefaultAzureCredential()).set_secret(secret, key)
    print(f"Stored {team_name} API key in Key Vault secret {secret}")


def ensure_policy(dt, spec, existing, restricted_group_uuid):
    if spec["name"] in existing:
        print(f"Policy exists: {spec['name']}")
        return
    policy = dt.call("PUT", "policy", json={"name": spec["name"], "operator": "ANY",
                                            "violationState": spec["violationState"]}).json()
    for cond in spec["conditions"]:
        value = restricted_group_uuid if cond["value"] == "@restricted-group" else cond["value"]
        dt.call("PUT", f"policy/{policy['uuid']}/condition", json={**cond, "value": value})
    for tag in spec.get("tags", []):
        dt.call("POST", f"policy/{policy['uuid']}/tag/{tag}", ok=(304,))
    print(f"Created policy: {spec['name']}")


def bootstrap(dt, args):
    props = [
        ("access-management", "acl.enabled", "true"),
        ("vuln-source", "nvd.enabled", "true"),
        ("vuln-source", "google.osv.enabled", ";".join(OSV_ECOSYSTEMS)),
    ]
    token = os.environ.get("GITHUB_ADVISORIES_TOKEN")
    if token:
        props += [("vuln-source", "github.advisories.enabled", "true"),
                  ("vuln-source", "github.advisories.access.token", token)]
    else:
        print("GITHUB_ADVISORIES_TOKEN not set: GitHub Advisories mirror left as is", file=sys.stderr)
    dt.call("POST", "configProperty/aggregate",
            json=[{"groupName": g, "propertyName": p, "propertyValue": v} for g, p, v in props])
    print("Portfolio access control on; NVD, OSV" + (", GitHub Advisories" if token else "") + " enabled")

    for name, perms in TEAMS.items():
        team = ensure_team(dt, name, perms)
        if name in KEY_SECRETS and args.generate_keys and not team.get("apiKeys"):
            key = dt.call("PUT", f"team/{team['uuid']}/key").json()["key"]
            store_key(name, key, args.key_vault_url)
    ensure_oidc_mapping(dt, CPS_ADMINS, dt.teams()[CPS_ADMINS]["uuid"])
    print(f"Teams ready: {', '.join(TEAMS)}; {CPS_ADMINS} mapped to its Entra group")

    groups = {g["name"]: g for g in dt.call("GET", "licenseGroup").json()}
    group = groups.get("CPS restricted") or dt.call("PUT", "licenseGroup", json={"name": "CPS restricted"}).json()
    for spdx_id in RESTRICTED_LICENCES:
        lic = dt.call("GET", f"license/{spdx_id}", ok=(404,))
        if lic.status_code == 404:
            print(f"Licence {spdx_id} not in this Dependency-Track's licence list; skipped", file=sys.stderr)
            continue
        dt.call("POST", f"licenseGroup/{group['uuid']}/license/{lic.json()['uuid']}", ok=(304,))
    existing = {p["name"] for p in dt.call("GET", "policy").json()}
    for spec in POLICIES:
        ensure_policy(dt, spec, existing, group["uuid"])


def onboard_org(dt, args):
    org = args.org
    parent_uuid = dt.ensure_parent(org)
    team = ensure_team(dt, ORG_TEAM.format(org=org), ORG_TEAM_PERMISSIONS)
    ensure_oidc_mapping(dt, team["name"], team["uuid"])
    teams = dt.teams()
    for name in [team["name"], *UPLOADER_TEAMS]:
        if name in teams:
            dt.grant(teams[name]["uuid"], parent_uuid)
    print(f"{org}: parent project {parent_uuid}, team {team['name']} mapped to its Entra group and ACL")

    if args.teams_webhook:
        publisher = next(p for p in dt.call("GET", "notification/publisher").json() if p["name"] == "Microsoft Teams")
        rules = {r["name"]: r for r in dt.call("GET", "notification/rule").json()}
        name = f"sbom-{org}"
        rule = rules.get(name) or dt.call("PUT", "notification/rule", json={
            "name": name, "scope": "PORTFOLIO", "notificationLevel": "INFORMATIONAL",
            "publisher": {"uuid": publisher["uuid"]}}).json()
        dt.call("POST", "notification/rule", json={
            **rule, "enabled": True, "notifyChildren": True,
            "notifyOn": ["NEW_VULNERABILITY", "POLICY_VIOLATION"],
            "publisherConfig": json.dumps({"destination": args.teams_webhook})})
        dt.call("POST", f"notification/rule/{rule['uuid']}/project/{parent_uuid}", ok=(304,))
        print(f"{org}: notifications for new vulnerabilities and policy violations go to the Teams webhook")

    granted, _ = dt.sync_acl()
    print(f"ACL sync: {granted} new mappings")


def sync_acl(dt, args):
    granted, missing = dt.sync_acl()
    print(f"ACL sync: {granted} new mappings")
    if missing:
        print(f"Parents with no team yet (run onboard-org): {', '.join(missing)}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("bootstrap", help="Access control, vulnerability sources, teams, API keys, starter policies")
    b.add_argument("--key-vault-url", help="Store generated API keys here (otherwise printed once to stderr)")
    b.add_argument("--no-generate-keys", dest="generate_keys", action="store_false",
                   help="Don't create API keys for teams that have none")
    o = sub.add_parser("onboard-org", help="Parent project, team, OIDC mapping, ACL and notifications for one org")
    o.add_argument("org", help="GitHub org login, exactly as GitHub spells it")
    o.add_argument("--teams-webhook", help="Teams incoming webhook URL for the org's channel")
    sub.add_parser("sync-acl", help="Grant each org's team access to every project under its parent")
    args = ap.parse_args()

    dt = DependencyTrack(os.environ["DTRACK_URL"], os.environ["DTRACK_ADMIN_API_KEY"])
    {"bootstrap": bootstrap, "onboard-org": onboard_org, "sync-acl": sync_acl}[args.cmd](dt, args)


if __name__ == "__main__":
    main()
