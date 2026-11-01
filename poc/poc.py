"""Run the SBOM collector locally against real GitHub, Dependency-Track in
Docker and Azurite. No Azure subscription needed. Setup: poc/README.md.

  python poc/poc.py dt-init --org <org>        # first-time Dependency-Track setup
  python poc/poc.py ratelimit <org> [--probe <repo>]
  python poc/poc.py collect <org>/<repo> [...]
  python poc/poc.py enumerate                   # every repo the App can see: mind the rate limit
  python poc/poc.py drain | acl | status

Settings come from sbom-collector/local.settings.json, as for `func start`.
Rows meant for Sentinel are written to poc/out/<stream>.jsonl instead.
"""
import argparse
import json
import os
import pathlib
import secrets
import sys
import time

POC = pathlib.Path(__file__).resolve().parent
COLLECTOR = POC.parent / "sbom-collector"
OUT = POC / "out"


def load_settings():
    path = COLLECTOR / "local.settings.json"
    if not path.is_file():
        sys.exit(f"{path} missing: copy local.settings.json.example and fill in GITHUB_APP_ID")
    for k, v in json.loads(path.read_text())["Values"].items():
        os.environ.setdefault(k, v)
    os.environ["LOCAL_SECRETS_DIR"] = str((COLLECTOR / os.environ["LOCAL_SECRETS_DIR"]).resolve())
    sys.path[:0] = [str(COLLECTOR), str(COLLECTOR / "ops")]


load_settings()

import dtrack_admin  # noqa: E402
import requests  # noqa: E402
from azure.core.exceptions import ResourceExistsError  # noqa: E402
from azure.data.tables import TableServiceClient  # noqa: E402
from azure.storage.blob import BlobServiceClient  # noqa: E402
from azure.storage.queue import QueueClient, TextBase64DecodePolicy  # noqa: E402

import function_app as fa  # noqa: E402
from dtrack import DependencyTrack  # noqa: E402

SECRETS = pathlib.Path(os.environ["LOCAL_SECRETS_DIR"])
DTRACK = os.environ["DTRACK_URL"].rstrip("/")


class Msg:
    """Just enough of func.QueueMessage for collect_sbom."""

    def __init__(self, body, dequeue_count):
        self._body, self.dequeue_count = body.encode(), dequeue_count

    def get_body(self):
        return self._body


# ---------- show what the collector does, and keep the Sentinel rows ----------
_finish, _requeue = fa._finish, fa._requeue


def _show_finish(job, status, count, detail="", extra=None):
    print(f"  {job['org']}/{job['repo']}: {status}, {count} components {detail}".rstrip())
    _finish(job, status, count, detail, extra)


def _show_requeue(job, delay):
    why = "waiting for GitHub to build the SBOM" if "sbom_url" in job else "rate-limited or report requested"
    print(f"  {job['org']}/{job['repo']}: back in {int(delay)}s ({why})")
    _requeue(job, delay)


def _write_rows(stream, rows):
    if rows:
        OUT.mkdir(exist_ok=True)
        with (OUT / f"{stream.removeprefix('Custom-')}.jsonl").open("a") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)


fa._finish, fa._requeue = _show_finish, _show_requeue
if not os.environ.get("DCE_ENDPOINT"):
    fa._send = _write_rows


# ---------- helpers ----------
def ensure_storage():
    conn = os.environ["SbomStorage"]
    for name in ("sbom-work", "sbom-work-poison"):
        try:
            QueueClient.from_connection_string(conn, name).create_queue()
        except ResourceExistsError:
            pass
    try:
        BlobServiceClient.from_connection_string(conn).create_container("sbom-raw")
    except ResourceExistsError:
        pass
    TableServiceClient.from_connection_string(conn).create_table_if_not_exists("repostate")


def require_dtrack():
    try:
        requests.get(f"{DTRACK}/api/version", timeout=5).raise_for_status()
    except requests.RequestException:
        sys.exit(f"Dependency-Track not reachable at {DTRACK}: `docker compose -f poc/docker-compose.yml up -d`")
    if not (SECRETS / "dtrack-api-key").is_file():
        sys.exit("No collector API key yet: run `python poc/poc.py dt-init --org <org>` first")


def gh(path, token):
    r = requests.get(f"{fa.GH}/{path}", headers=fa._h(token), timeout=30)
    r.raise_for_status()
    return r


def installation(org):
    try:
        return gh(f"orgs/{org}/installation", fa._app_jwt()).json()["id"]
    except requests.HTTPError as e:
        sys.exit(f"The App isn't installed on {org} ({e}); install it with access to the repos to test")


def drain(poll=10):
    """What the Functions host does: run collect_sbom per message; on the last
    failed attempt move the message to sbom-work-poison."""
    conn = os.environ["SbomStorage"]
    work = QueueClient.from_connection_string(conn, "sbom-work", message_decode_policy=TextBase64DecodePolicy())
    poison = fa._queue("sbom-work-poison")
    while True:
        msgs = list(work.receive_messages(max_messages=8, visibility_timeout=60))
        for m in msgs:
            try:
                fa.collect_sbom(Msg(m.content, m.dequeue_count))
                work.delete_message(m)
            except Exception as e:  # noqa: BLE001 - mirrors the host's retry
                job = json.loads(m.content)
                print(f"  {job['org']}/{job['repo']}: attempt {m.dequeue_count} failed: {type(e).__name__}: {e}")
                if m.dequeue_count >= fa.MAX_DEQUEUE:
                    poison.send_message(m.content)
                    work.delete_message(m)
        if msgs:
            continue
        waiting = work.get_queue_properties().approximate_message_count
        if not waiting:
            return
        print(f"... {waiting} job(s) not due yet; checking every {poll}s (Ctrl-C is safe, `drain` resumes)")
        time.sleep(poll)


# ---------- commands ----------
def cmd_dt_init(args):
    """Change the default admin password, make an admin API key, then run
    dtrack_admin.py bootstrap and onboard-org with keys written to poc/secrets."""
    SECRETS.mkdir(exist_ok=True)
    for _ in range(60):
        try:
            if requests.get(f"{DTRACK}/api/version", timeout=5).ok:
                break
        except requests.RequestException:
            pass
        print("Waiting for Dependency-Track to start...")
        time.sleep(10)
    else:
        sys.exit(f"Dependency-Track not up at {DTRACK}; see `docker compose -f poc/docker-compose.yml logs`")

    pw_file, key_file = SECRETS / "dtrack-admin-password", SECRETS / "dtrack-admin-api-key"
    if not key_file.is_file():
        if not pw_file.is_file():
            pw = secrets.token_urlsafe(18)
            r = requests.post(f"{DTRACK}/api/v1/user/forceChangePassword", timeout=30, data={
                "username": "admin", "password": "admin", "newPassword": pw, "confirmPassword": pw})
            r.raise_for_status()
            pw_file.touch(mode=0o600)
            pw_file.write_text(pw)
            print(f"Changed the Dependency-Track admin password; it is in {pw_file}")
        r = requests.post(f"{DTRACK}/api/v1/user/login", timeout=30,
                          data={"username": "admin", "password": pw_file.read_text()})
        r.raise_for_status()
        bearer = {"Authorization": f"Bearer {r.text}"}
        teams = requests.get(f"{DTRACK}/api/v1/team", headers=bearer, timeout=30).json()
        admins = next(t for t in teams if t["name"] == "Administrators")
        r = requests.put(f"{DTRACK}/api/v1/team/{admins['uuid']}/key", headers=bearer, timeout=30)
        r.raise_for_status()
        key_file.touch(mode=0o600)
        key_file.write_text(r.json()["key"])
        print(f"Created an Administrators API key in {key_file}")

    dt = DependencyTrack(DTRACK, key_file.read_text().strip())
    dtrack_admin.bootstrap(dt, argparse.Namespace(key_vault_url=None, generate_keys=True))
    for org in args.org:
        dtrack_admin.onboard_org(dt, argparse.Namespace(org=org, teams_webhook=None))


def cmd_ratelimit(args):
    """Phase 1 check: what limit does an App installation get for dependency_sbom?"""
    token = fa._install_token(installation(args.org))
    r = gh("rate_limit", token)
    result = {"org": args.org, "rate_limit": r.json()["resources"]}
    print(f"{'resource':28} {'limit':>7} {'remaining':>9}")
    for name, v in sorted(result["rate_limit"].items()):
        print(f"{name:28} {v['limit']:>7} {v['remaining']:>9}")
    if args.probe:
        r = requests.get(f"{fa.GH}/repos/{args.org}/{args.probe}/dependency-graph/sbom/generate-report",
                         headers=fa._h(token), timeout=30)
        result["probe"] = {"status": r.status_code,
                           **{k: v for k, v in r.headers.items() if k.lower().startswith("x-ratelimit")}}
        print(f"\ngenerate-report on {args.org}/{args.probe}: HTTP {r.status_code}")
        for k, v in result["probe"].items():
            if k != "status":
                print(f"  {k}: {v}")
    OUT.mkdir(exist_ok=True)
    (OUT / f"ratelimit-{args.org}.json").write_text(json.dumps(result, indent=2))
    print(f"\nSaved to {OUT / f'ratelimit-{args.org}.json'}; note the dependency_sbom limit in the delivery plan")


def cmd_collect(args):
    require_dtrack()
    ensure_storage()
    for full in args.repos:
        org, _, repo = full.partition("/")
        if not repo:
            sys.exit(f"{full}: expected <org>/<repo>")
        inst = installation(org)
        meta = gh(f"repos/{org}/{repo}", fa._install_token(inst)).json()
        fa._queue().send_message(json.dumps({
            "org": org, "repo": repo, "installation_id": inst, "branch": meta["default_branch"],
            "pushed_at": meta["pushed_at"], "attempt": 0}))
        print(f"Queued {org}/{repo}")
    drain()
    cmd_status(args)


def cmd_enumerate(args):
    require_dtrack()
    ensure_storage()
    fa.enumerate_repos(None)
    drain()
    cmd_status(args)


def cmd_drain(args):
    require_dtrack()
    drain()
    cmd_status(args)


def cmd_acl(args):
    require_dtrack()
    fa.sync_dtrack_acl(None)
    print("ACL sync done (see log lines above)")


def cmd_status(args):
    ensure_storage()
    rows = sorted(fa._state().list_entities(), key=lambda e: (e["PartitionKey"], e["RowKey"]))
    print(f"\n{'repo':50} {'status':20} {'components':>10}  last run")
    for e in rows:
        print(f"{e['PartitionKey'] + '/' + e['RowKey']:50} {e['LastStatus']:20} {e['ComponentCount']:>10}  "
              f"{e['LastRun'][:19]}")
    blobs = sum(1 for _ in fa._blobs().list_blobs())
    print(f"\n{len(rows)} repos, {blobs} raw SBOMs in Azurite. Dependency-Track: http://localhost:8080 "
          f"(admin password in {SECRETS / 'dtrack-admin-password'}). Sentinel rows: {OUT}/")


def main():
    import logging

    logging.basicConfig(level=logging.INFO, format="  %(message)s")
    for noisy in ("azure", "urllib3"):
        logging.getLogger(noisy).setLevel(logging.WARNING)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("dt-init", help="First-time Dependency-Track setup (admin password, keys, bootstrap)")
    p.add_argument("--org", action="append", default=[], help="Org to onboard (repeatable)")
    p = sub.add_parser("ratelimit", help="Show the App installation's rate limits, including dependency_sbom")
    p.add_argument("org")
    p.add_argument("--probe", metavar="REPO", help="Also call generate-report once on this repo and show its headers")
    p = sub.add_parser("collect", help="Collect named repos end to end")
    p.add_argument("repos", nargs="+", metavar="ORG/REPO")
    sub.add_parser("enumerate", help="Run the nightly enumeration over every installation, then drain")
    sub.add_parser("drain", help="Process whatever is left on the queue")
    sub.add_parser("acl", help="Run the nightly Dependency-Track ACL sync")
    sub.add_parser("status", help="Per-repo outcome from the repostate table")
    args = ap.parse_args()
    globals()[f"cmd_{args.cmd.replace('-', '_')}"](args)


if __name__ == "__main__":
    main()
