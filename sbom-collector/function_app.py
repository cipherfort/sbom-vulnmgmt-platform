"""SBOM collector: GitHub's dependency-graph SBOM for every repo in the org,
archived to Blob and loaded into Dependency-Track."""
import base64
import datetime as dt
import json
import logging
import os
import time
from functools import cache, lru_cache

import azure.functions as func
import jwt
import requests
from azure.core.exceptions import ResourceNotFoundError
from azure.data.tables import TableServiceClient, UpdateMode
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient
from azure.storage.queue import QueueClient, TextBase64EncodePolicy

from convert import refresh_weekday, spdx_to_cyclonedx
from dtrack import DependencyTrack

app = func.FunctionApp()
GH, GH_VER = "https://api.github.com", "2026-03-10"
ACCOUNT = os.environ["SBOM_STORAGE_ACCOUNT"]
MAX_DEQUEUE = 5  # keep in step with host.json maxDequeueCount
CRED = DefaultAzureCredential()  # user-assigned identity, picked by AZURE_CLIENT_ID
APP_ID = os.environ["GITHUB_APP_ID"]
_tokens: dict = {}

# ---------- Azure clients ----------
@lru_cache
def _secret(name):
    return SecretClient(os.environ["KEY_VAULT_URL"], CRED).get_secret(name).value

def _storage(cls, service, **kw):
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

def _now():
    return dt.datetime.now(dt.UTC).isoformat()

def _report(org, repo, status, count, detail=""):
    """One log line per repo per run; kql/collector-status.kql reads these."""
    (logging.warning if status == "error" else logging.info)("sbom-result %s", json.dumps(
        {"Org": org, "Repo": repo, "Status": status, "ComponentCount": count, "Detail": detail}))

# ---------- GitHub auth ----------
def _h(token):
    return {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": GH_VER}

def _app_jwt():
    now = int(time.time())
    return jwt.encode({"iat": now - 60, "exp": now + 540, "iss": APP_ID},
                      _secret("github-app-private-key"), algorithm="RS256")

def _install_token(installation_id):
    tok, exp = _tokens.get(installation_id, (None, 0))
    if tok and exp - time.time() > 300:
        return tok
    r = requests.post(f"{GH}/app/installations/{installation_id}/access_tokens",
                      headers=_h(_app_jwt()), timeout=30)
    r.raise_for_status()
    body = r.json()
    exp = dt.datetime.fromisoformat(body["expires_at"].replace("Z", "+00:00")).timestamp()
    _tokens[installation_id] = (body["token"], exp)
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
    """Queues every repo the App can see that changed, plus a rolling 1/7 of the rest."""
    today = dt.datetime.now(dt.UTC).weekday()
    skipped = queued = 0
    for inst in _paged(f"{GH}/app/installations", _app_jwt()):
        org = inst["account"]["login"]
        token = _install_token(inst["id"])
        for repo in _paged(f"{GH}/installation/repositories", token, key="repositories"):
            name = repo["name"]
            if repo["archived"] or repo.get("disabled") or repo["size"] == 0:
                _report(org, name, "skipped", 0, "archived, disabled or empty")
                skipped += 1
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
    logging.info("Queued %d repos, skipped %d", queued, skipped)

# ---------- 2. Per-repo worker ----------
def _requeue(job, delay):
    _queue().send_message(json.dumps(job), visibility_timeout=int(delay))

def _throttled(r, job):
    """On a rate limit, park the job until the limit resets instead of failing it."""
    if r.status_code in (403, 429) and (r.headers.get("retry-after") or r.headers.get("x-ratelimit-remaining") == "0"):
        reset = int(r.headers.get("x-ratelimit-reset", time.time() + 60))
        wait = int(r.headers.get("retry-after") or max(reset - time.time(), 60))
        _requeue(job, min(wait, 3600))
        return True
    return False

def _finish(job, status, count, detail=""):
    _report(job["org"], job["repo"], status, count, detail)
    _state().upsert_entity({"PartitionKey": job["org"], "RowKey": job["repo"], "PushedAt": job["pushed_at"],
                            "LastStatus": status, "ComponentCount": count, "LastRun": _now()},
                           mode=UpdateMode.MERGE)

@app.queue_trigger(arg_name="msg", queue_name="sbom-work", connection="SbomStorage")
def collect_sbom(msg: func.QueueMessage) -> None:
    job = json.loads(msg.get_body().decode())
    try:
        _collect(job)
    except Exception as e:
        # Last attempt: record the failure before the message goes to the poison queue.
        if msg.dequeue_count >= MAX_DEQUEUE:
            _finish(job, "error", 0, f"{type(e).__name__}: {e}"[:500])
        raise

def _collect(job):
    org, repo = job["org"], job["repo"]
    token = _install_token(job["installation_id"])

    # Step A: ask GitHub to build the SBOM
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
    cdx = spdx_to_cyclonedx(spdx, org, repo, job["branch"])
    _dtrack_upload(cdx, org, repo, job["branch"])
    _finish(job, "ok", len(cdx["components"]))

# ---------- 3. Dependency-Track upload ----------
@cache
def _dt():
    return DependencyTrack(os.environ["DTRACK_URL"], _secret("dtrack-api-key"))

@cache
def _dtrack_parent(org):
    return _dt().ensure_parent(org)

def _dtrack_upload(cdx, org, repo, branch):
    _dt().upload_bom(f"{org}/{repo}", branch, _dtrack_parent(org),
                     base64.b64encode(json.dumps(cdx).encode()).decode())

# ---------- 4. Every 15 minutes: poison-queue depth for the alert ----------
@app.timer_trigger(schedule="0 */15 * * * *", arg_name="timer")
def report_poison_depth(timer: func.TimerRequest) -> None:
    """Azure Monitor has no per-queue length metric; monitoring.tf alerts on this line."""
    depth = _queue("sbom-work-poison").get_queue_properties().approximate_message_count
    (logging.warning if depth else logging.info)("sbom-poison-depth=%d", depth)
