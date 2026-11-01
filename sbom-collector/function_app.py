"""CPS enterprise SBOM collector: GitHub dependency-graph SBOMs -> Blob,
Dependency-Track, Sentinel. Design: docs/enterprise-sbom/, ADR-0002."""
import base64
import datetime as dt
import json
import logging
import os
import pathlib
import time
from functools import cache, lru_cache

import azure.functions as func
import jwt
import requests
from azure.core.exceptions import ResourceNotFoundError
from azure.data.tables import TableServiceClient, UpdateMode
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.monitor.ingestion import LogsIngestionClient
from azure.storage.blob import BlobServiceClient
from azure.storage.queue import QueueClient, TextBase64EncodePolicy

from convert import refresh_weekday, sentinel_rows, spdx_to_cyclonedx
from dtrack import DependencyTrack

app = func.FunctionApp()
GH, GH_VER = "https://api.github.com", "2026-03-10"
ACCOUNT = os.environ["SBOM_STORAGE_ACCOUNT"]
MAX_DEQUEUE = 5  # keep in step with host.json maxDequeueCount
SEVERITIES = ("critical", "high", "medium", "low")
CRED = DefaultAzureCredential()  # user-assigned identity, picked by AZURE_CLIENT_ID
APPS = {  # app name -> (app id, Key Vault secret holding its private key)
    "collector": (os.environ["GITHUB_APP_ID"], "github-app-private-key"),
    "installer": (os.environ.get("GITHUB_INSTALLER_APP_ID", ""), "github-installer-private-key"),
}
_tokens: dict = {}

# ---------- Azure clients (managed identity everywhere) ----------
# Local runs (poc/) set LOCAL_SECRETS_DIR and a SbomStorage connection string
# for Azurite. Azure never sets either: there SbomStorage is identity-based
# (SbomStorage__queueServiceUri and friends).
@lru_cache
def _secret(name):
    local = os.environ.get("LOCAL_SECRETS_DIR")
    if local:  # one file per secret, named as in Key Vault
        path = pathlib.Path(local, name)
        if not path.is_file():
            raise ResourceNotFoundError(f"{path} not found")
        return path.read_text().strip()
    return SecretClient(os.environ["KEY_VAULT_URL"], CRED).get_secret(name).value

def _storage(cls, service, **kw):
    conn = os.environ.get("SbomStorage")
    if conn:
        return cls.from_connection_string(conn, **kw)
    return cls(f"https://{ACCOUNT}.{service}.core.windows.net", credential=CRED, **kw)

@lru_cache
def _queue(name="sbom-work"):
    return _storage(QueueClient, "queue", queue_name=name, message_encode_policy=TextBase64EncodePolicy())

@lru_cache
def _state():
    return _storage(TableServiceClient, "table").get_table_client("repostate")

@lru_cache
def _blobs():
    return _storage(BlobServiceClient, "blob").get_container_client("sbom-raw")

@lru_cache
def _logs():
    return LogsIngestionClient(endpoint=os.environ["DCE_ENDPOINT"], credential=CRED)

def _send(stream, rows):
    if not rows:
        return
    if not os.environ.get("DCE_ENDPOINT"):  # local runs without Sentinel
        logging.info("DCE_ENDPOINT unset; not sending %d rows to %s", len(rows), stream)
        return
    _logs().upload(rule_id=os.environ["DCR_IMMUTABLE_ID"], stream_name=stream, logs=rows)

def _now():
    return dt.datetime.now(dt.UTC).isoformat()

# ---------- GitHub auth ----------
def _h(token):
    return {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": GH_VER}

def _app_jwt(app_name="collector"):
    app_id, key_name = APPS[app_name]
    now = int(time.time())
    return jwt.encode({"iat": now - 60, "exp": now + 540, "iss": app_id},
                      _secret(key_name), algorithm="RS256")

def _install_token(installation_id, app_name="collector"):
    tok, exp = _tokens.get((app_name, installation_id), (None, 0))
    if tok and exp - time.time() > 300:
        return tok
    r = requests.post(f"{GH}/app/installations/{installation_id}/access_tokens",
                      headers=_h(_app_jwt(app_name)), timeout=30)
    r.raise_for_status()
    body = r.json()
    exp = dt.datetime.fromisoformat(body["expires_at"].replace("Z", "+00:00")).timestamp()
    _tokens[(app_name, installation_id)] = (body["token"], exp)
    return body["token"]

def _paged(url, token, key=None, params=None):
    params = {"per_page": 100, **(params or {})}
    while url:
        r = requests.get(url, headers=_h(token), params=params, timeout=30)
        r.raise_for_status()
        data = r.json()
        yield from (data[key] if key else data)
        url, params = r.links.get("next", {}).get("url"), None  # next link already carries the query

# ---------- 1. Nightly enumeration (02:00 UTC; Flex Consumption has no time zone setting) ----------
@app.timer_trigger(schedule="0 0 2 * * *", arg_name="timer", use_monitor=True)
def enumerate_repos(timer: func.TimerRequest) -> None:
    today = dt.datetime.now(dt.UTC).weekday()
    skipped, queued = [], 0
    for inst in _paged(f"{GH}/app/installations", _app_jwt()):
        org = inst["account"]["login"]
        token = _install_token(inst["id"])
        for repo in _paged(f"{GH}/installation/repositories", token, key="repositories"):
            name = repo["name"]
            if repo["archived"] or repo.get("disabled") or repo["size"] == 0:
                skipped.append({"TimeGenerated": _now(), "Org": org, "Repo": name, "Status": "skipped",
                                "ComponentCount": 0, "PushedAt": repo.get("pushed_at"),
                                "Detail": "archived, disabled or empty"})
                continue
            if refresh_weekday(org, name) != today:
                try:
                    seen = _state().get_entity(org, name)
                    if seen.get("PushedAt") == repo["pushed_at"] and seen.get("LastStatus") == "ok":
                        continue  # unchanged since last good SBOM
                except ResourceNotFoundError:
                    pass
            _queue().send_message(json.dumps({
                "org": org, "repo": name, "installation_id": inst["id"],
                "branch": repo["default_branch"], "pushed_at": repo["pushed_at"], "attempt": 0}))
            queued += 1
    _send("Custom-GitHubSbomRun", skipped)
    logging.info("Queued %d repos, skipped %d", queued, len(skipped))

# ---------- 2. Per-repo worker ----------
def _requeue(job, delay):
    _queue().send_message(json.dumps(job), visibility_timeout=int(delay))

def _throttled(r, job):
    """On a rate limit, park the job until the limit resets instead of failing it.
    generate-report has its own bucket (dependency_sbom), so this fires there first."""
    if r.status_code in (403, 429) and (r.headers.get("retry-after") or r.headers.get("x-ratelimit-remaining") == "0"):
        reset = int(r.headers.get("x-ratelimit-reset", time.time() + 60))
        wait = int(r.headers.get("retry-after") or max(reset - time.time(), 60))
        _requeue(job, min(wait, 3600))
        return True
    return False

def _finish(job, status, count, detail="", extra=None):
    _send("Custom-GitHubSbomRun", [{"TimeGenerated": _now(), "Org": job["org"], "Repo": job["repo"],
                                    "Status": status, "ComponentCount": count,
                                    "PushedAt": job["pushed_at"], "Detail": detail, **(extra or {})}])
    _state().upsert_entity({"PartitionKey": job["org"], "RowKey": job["repo"], "PushedAt": job["pushed_at"],
                            "LastStatus": status, "ComponentCount": count, "LastRun": _now()},
                           mode=UpdateMode.MERGE)

@app.queue_trigger(arg_name="msg", queue_name="sbom-work", connection="SbomStorage")
def collect_sbom(msg: func.QueueMessage) -> None:
    job = json.loads(msg.get_body().decode())
    try:
        _collect(job)
    except Exception as e:
        # Last attempt: record the failure before the host moves the message
        # to sbom-work-poison, so the coverage dashboard shows it.
        if msg.dequeue_count >= MAX_DEQUEUE:
            _finish(job, "error", 0, f"{type(e).__name__}: {e}"[:500])
        raise

def _collect(job):
    org, repo = job["org"], job["repo"]
    token = _install_token(job["installation_id"])

    # Step A: ask GitHub to build the SBOM (async API; the old sync endpoint goes 13 Nov 2026)
    if "sbom_url" not in job:
        r = requests.get(f"{GH}/repos/{org}/{repo}/dependency-graph/sbom/generate-report",
                         headers=_h(token), timeout=30)
        if _throttled(r, job):
            return
        if r.status_code == 404:
            _finish(job, "no-dependency-graph", 0, r.text[:200])
            return
        r.raise_for_status()
        job["sbom_url"] = r.json()["sbom_url"]
        _requeue(job, 30)
        return

    # Step B: poll; 202 = still building, 302 = ready (redirect to a short-lived download URL)
    r = requests.get(job["sbom_url"], headers=_h(token), allow_redirects=False, timeout=30)
    if _throttled(r, job):
        return
    if r.status_code == 202:
        job["attempt"] += 1
        if job["attempt"] > 20:
            _finish(job, "timeout", 0, "SBOM not ready after 20 polls")
            return
        _requeue(job, min(30 * 2 ** (job["attempt"] - 1), 300))
        return
    if r.status_code != 302:
        r.raise_for_status()
        raise RuntimeError(f"Unexpected status {r.status_code} for {org}/{repo}")
    # Pre-signed Blob URL, valid ~5 minutes: download now, and never send the GitHub token there.
    dl = requests.get(r.headers["Location"], timeout=120)
    dl.raise_for_status()
    body = dl.json()
    spdx = body.get("sbom", body)  # GitHub returns bare SPDX today; tolerate the wrapped form too

    # Step C: archive, convert, load
    _blobs().upload_blob(f"{org}/{repo}/{dt.date.today().isoformat()}.spdx.json", json.dumps(spdx), overwrite=True)
    ts = _now()
    cdx = spdx_to_cyclonedx(spdx, org, repo, job["branch"], timestamp=ts)
    _dtrack_upload(cdx, org, repo, job["branch"])
    rows = sentinel_rows(cdx, org, repo, job["branch"], ts)
    _send("Custom-GitHubSbom", rows)
    _finish(job, "ok", len(rows), extra=_dependabot_counts(org, repo, token))

def _dependabot_counts(org, repo, token):
    """Phase 3: open Dependabot alerts by severity. Never fails the job: a repo
    with Dependabot alerts off (403/404) or a transient error gets no counts."""
    counts = dict.fromkeys(SEVERITIES, 0)
    try:
        for alert in _paged(f"{GH}/repos/{org}/{repo}/dependabot/alerts", token, params={"state": "open"}):
            sev = (alert.get("security_vulnerability") or {}).get("severity", "")
            if sev in counts:
                counts[sev] += 1
    except requests.RequestException as e:
        logging.info("No Dependabot counts for %s/%s: %s", org, repo, e)
        return {}
    return {f"Dependabot{s.capitalize()}": n for s, n in counts.items()}

# ---------- 3. Dependency-Track: upload, and the nightly ACL sync ----------
@cache
def _dt(secret="dtrack-api-key"):
    return DependencyTrack(os.environ["DTRACK_URL"], _secret(secret))

@cache
def _dtrack_parent(org):
    return _dt().ensure_parent(org)

def _dtrack_upload(cdx, org, repo, branch):
    _dt().upload_bom(f"{org}/{repo}", branch, _dtrack_parent(org),
                     base64.b64encode(json.dumps(cdx).encode()).decode())

@app.timer_trigger(schedule="0 30 4 * * *", arg_name="timer")
def sync_dtrack_acl(timer: func.TimerRequest) -> None:
    """N2: give each org's team access to every project under its parent.
    Uses a separate key (team acl-sync, ACCESS_MANAGEMENT) so the upload key
    stays least-privileged. Skipped until that key exists (phase 2)."""
    try:
        dtc = _dt("dtrack-acl-key")
    except ResourceNotFoundError:
        logging.info("Key Vault secret dtrack-acl-key not set; ACL sync disabled")
        return
    granted, missing = dtc.sync_acl()
    logging.info("Dependency-Track ACL sync: %d new mappings", granted)
    if missing:
        logging.warning("No Dependency-Track team for org(s) %s: run dtrack_admin.py onboard-org", ", ".join(missing))

# ---------- 4. Every 15 minutes: poison-queue depth for the N5 alert ----------
@app.timer_trigger(schedule="0 */15 * * * *", arg_name="timer")
def report_poison_depth(timer: func.TimerRequest) -> None:
    """Azure Monitor has no per-queue length metric; monitoring.tf alerts on this line."""
    depth = _queue("sbom-work-poison").get_queue_properties().approximate_message_count
    (logging.warning if depth else logging.info)("sbom-poison-depth=%d", depth)

# ---------- 5. Weekly: install the collector on any new org (phase 2) ----------
@app.timer_trigger(schedule="0 0 3 * * 1", arg_name="timer")
def install_collector_on_new_orgs(timer: func.TimerRequest) -> None:
    if not APPS["installer"][0]:
        logging.info("GITHUB_INSTALLER_APP_ID not set; installer disabled")
        return
    ent = os.environ["GITHUB_ENTERPRISE"]
    token = _install_token(os.environ["GITHUB_INSTALLER_INSTALLATION_ID"], app_name="installer")
    r = requests.get(f"{GH}/app", headers=_h(_app_jwt()), timeout=30)
    r.raise_for_status()
    client_id = r.json()["client_id"]
    failed = []
    for org in _paged(f"{GH}/enterprises/{ent}/apps/installable_organizations", token):
        login = org["login"]
        base = f"{GH}/enterprises/{ent}/apps/organizations/{login}/installations"
        # The list response has client_id but not app_id, so match on client_id.
        mine = [i for i in _paged(base, token) if i.get("client_id") == client_id]
        if mine:
            if mine[0].get("repository_selection") != "all":  # "404 on every repo in an org" in the runbook
                r = requests.patch(f"{base}/{mine[0]['id']}/repositories", headers=_h(token),
                                   json={"repository_selection": "all"}, timeout=30)
                logging.warning("Set collector on org %s to all repositories: HTTP %s", login, r.status_code)
                if not r.ok:
                    failed.append(login)
            continue
        r = requests.post(base, headers=_h(token), json={"client_id": client_id, "repository_selection": "all"},
                          timeout=30)
        logging.warning("Installed collector on new org %s: HTTP %s", login, r.status_code)
        if not r.ok:
            failed.append(login)
    if failed:
        raise RuntimeError(f"Collector install or update failed on: {', '.join(failed)}")
