import json
from unittest import mock

import pytest
import requests
from azure.core.exceptions import ResourceNotFoundError
from conftest import Msg, Resp

import function_app as fa

JOB = {"org": "cps", "repo": "svc", "installation_id": 42, "branch": "main",
       "pushed_at": "2026-10-26T10:00:00Z", "attempt": 0}
SBOM_URL = "https://api.github.com/repos/cps/svc/dependency-graph/sbom/fetch-report/abc"


@pytest.fixture
def env(monkeypatch):
    """Stub every Azure and Dependency-Track edge; record what the collector sends."""
    sent, requeued = [], []
    state = mock.Mock()
    blobs = mock.Mock()
    monkeypatch.setattr(fa, "_install_token", lambda *a, **k: "ghs_token")
    monkeypatch.setattr(fa, "_send", lambda stream, rows: sent.append((stream, rows)))
    monkeypatch.setattr(fa, "_requeue", lambda job, delay: requeued.append((json.loads(json.dumps(job)), delay)))
    monkeypatch.setattr(fa, "_state", lambda: state)
    monkeypatch.setattr(fa, "_blobs", lambda: blobs)
    monkeypatch.setattr(fa, "_dtrack_upload", mock.Mock())
    return mock.Mock(sent=sent, requeued=requeued, state=state, blobs=blobs)


def runs(env):
    return [row for stream, rows in env.sent if stream == "Custom-GitHubSbomRun" for row in rows]


def test_generate_report_requeues_with_sbom_url(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(201, {"sbom_url": SBOM_URL})))
    fa.collect_sbom(Msg(JOB))
    ((job, delay),) = env.requeued
    assert job["sbom_url"] == SBOM_URL and delay == 30


def test_generate_report_404_is_coverage_not_failure(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(404, text="Not Found")))
    fa.collect_sbom(Msg(JOB))
    (row,) = runs(env)
    assert row["Status"] == "no-dependency-graph" and row["ComponentCount"] == 0
    assert env.state.upsert_entity.call_args.args[0]["LastStatus"] == "no-dependency-graph"


def test_rate_limited_job_is_parked_until_reset(env, monkeypatch):
    limited = Resp(403, headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(fa.time.time()) + 900)})
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=limited))
    fa.collect_sbom(Msg(JOB))
    ((job, delay),) = env.requeued
    assert "sbom_url" not in job and 880 <= delay <= 900
    assert runs(env) == []


def test_retry_after_is_honoured_and_capped(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(429, headers={"retry-after": "99999"})))
    fa.collect_sbom(Msg(JOB))
    assert env.requeued[0][1] == 3600


@pytest.mark.parametrize("attempt,delay", [(0, 30), (1, 60), (2, 120), (3, 240), (4, 300), (10, 300)])
def test_poll_202_backs_off(env, monkeypatch, attempt, delay):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(202)))
    fa.collect_sbom(Msg({**JOB, "sbom_url": SBOM_URL, "attempt": attempt}))
    ((job, got),) = env.requeued
    assert job["attempt"] == attempt + 1 and got == delay


def test_poll_gives_up_after_20(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(202)))
    fa.collect_sbom(Msg({**JOB, "sbom_url": SBOM_URL, "attempt": 20}))
    assert env.requeued == [] and runs(env)[0]["Status"] == "timeout"


def test_ready_sbom_is_archived_loaded_and_shipped(env, monkeypatch, spdx):
    def get(url, headers=None, **kw):
        if url == SBOM_URL:
            return Resp(302, headers={"Location": "https://blob.example/sbom.json?sig=x"})
        if url.startswith("https://blob.example/"):
            assert headers is None  # the GitHub token must never go to the download host
            return Resp(200, spdx)
        if url.endswith("/dependabot/alerts"):
            return Resp(200, [{"security_vulnerability": {"severity": s}} for s in ("critical", "high", "high")])
        raise AssertionError(url)

    monkeypatch.setattr(fa.requests, "get", get)
    fa.collect_sbom(Msg({**JOB, "sbom_url": SBOM_URL, "attempt": 3}))

    blob_name, body = env.blobs.upload_blob.call_args.args[:2]
    assert blob_name.startswith("cps/svc/") and blob_name.endswith(".spdx.json")
    assert json.loads(body) == spdx

    cdx = fa._dtrack_upload.call_args.args[0]
    assert len(cdx["components"]) == len(spdx["packages"]) - 1

    (sbom_rows,) = [rows for stream, rows in env.sent if stream == "Custom-GitHubSbom"]
    assert len(sbom_rows) == len(cdx["components"])
    (run,) = runs(env)
    assert run["Status"] == "ok" and run["ComponentCount"] == len(sbom_rows)
    counts = [run[f"Dependabot{s}"] for s in ("Critical", "High", "Medium", "Low")]
    assert counts == [1, 2, 0, 0]


def test_dependabot_counts_absent_when_alerts_off(monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(403)))
    assert fa._dependabot_counts("cps", "svc", "t") == {}


def test_last_attempt_records_error_then_reraises(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(500)))
    with pytest.raises(requests.HTTPError):
        fa.collect_sbom(Msg(JOB, dequeue_count=fa.MAX_DEQUEUE))
    (row,) = runs(env)
    assert row["Status"] == "error" and "500" in row["Detail"]


def test_earlier_attempts_reraise_without_a_row(env, monkeypatch):
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(500)))
    with pytest.raises(requests.HTTPError):
        fa.collect_sbom(Msg(JOB, dequeue_count=1))
    assert runs(env) == []


# ---------- Dependency-Track ACL sync (phase 2) ----------

def test_acl_sync_skipped_without_key(monkeypatch):
    fa._dt.cache_clear()
    def missing(name):
        raise ResourceNotFoundError("no such secret")
    monkeypatch.setattr(fa, "_secret", missing)
    fa.sync_dtrack_acl(None)  # no exception, nothing called
    fa._dt.cache_clear()


# ---------- Enumeration ----------

def test_enumerate_skips_and_queues(monkeypatch):
    repos = [
        {"name": "old", "archived": True, "size": 10, "pushed_at": "x", "default_branch": "main"},
        {"name": "same", "archived": False, "size": 10, "pushed_at": "p1", "default_branch": "main"},
        {"name": "changed", "archived": False, "size": 10, "pushed_at": "p2", "default_branch": "main"},
        {"name": "new", "archived": False, "size": 10, "pushed_at": "p3", "default_branch": "trunk"},
    ]

    def paged(url, token, key=None, params=None):
        return iter([{"id": 7, "account": {"login": "cps"}}]) if url.endswith("/app/installations") else iter(repos)

    def get_entity(org, name):
        if name == "new":
            raise ResourceNotFoundError("missing")
        return {"PushedAt": "p1", "LastStatus": "ok"}

    queue, sent = mock.Mock(), []
    monkeypatch.setattr(fa, "_paged", paged)
    monkeypatch.setattr(fa, "_app_jwt", lambda *a: "jwt")
    monkeypatch.setattr(fa, "_install_token", lambda *a, **k: "t")
    monkeypatch.setattr(fa, "_state", lambda: mock.Mock(get_entity=get_entity))
    monkeypatch.setattr(fa, "_queue", lambda *a: queue)
    monkeypatch.setattr(fa, "_send", lambda stream, rows: sent.extend(rows))
    monkeypatch.setattr(fa, "refresh_weekday", lambda org, name: 99)  # not today's refresh day

    fa.enumerate_repos(None)

    queued = [json.loads(c.args[0]) for c in queue.send_message.call_args_list]
    assert [j["repo"] for j in queued] == ["changed", "new"]
    assert queued[1]["branch"] == "trunk" and queued[1]["installation_id"] == 7
    assert [r["Repo"] for r in sent] == ["old"] and sent[0]["Status"] == "skipped"


# ---------- Installer (phase 2) ----------

def test_installer_disabled_without_app_id(monkeypatch):
    monkeypatch.setitem(fa.APPS, "installer", ("", "github-installer-private-key"))
    post = mock.Mock()
    monkeypatch.setattr(fa.requests, "post", post)
    fa.install_collector_on_new_orgs(None)
    post.assert_not_called()


def test_installer_installs_and_repairs(monkeypatch):
    monkeypatch.setitem(fa.APPS, "installer", ("999", "github-installer-private-key"))
    monkeypatch.setenv("GITHUB_INSTALLER_INSTALLATION_ID", "5")
    monkeypatch.setattr(fa, "_install_token", lambda *a, **k: "t")
    monkeypatch.setattr(fa, "_app_jwt", lambda *a: "jwt")
    monkeypatch.setattr(fa.requests, "get", mock.Mock(return_value=Resp(200, {"client_id": "Iv1.collector"})))
    installs = {
        "has-it": [{"id": 1, "client_id": "Iv1.collector", "repository_selection": "all"}],
        "selected": [{"id": 2, "client_id": "Iv1.collector", "repository_selection": "selected"}],
        "new-org": [{"id": 3, "client_id": "Iv1.other-app", "repository_selection": "all"}],
    }

    def paged(url, token, key=None, params=None):
        if url.endswith("/installable_organizations"):
            return iter([{"login": o} for o in installs])
        return iter(installs[url.split("/organizations/")[1].split("/")[0]])

    monkeypatch.setattr(fa, "_paged", paged)
    post, patch = mock.Mock(return_value=Resp(201, {"id": 4})), mock.Mock(return_value=Resp(200, {}))
    monkeypatch.setattr(fa.requests, "post", post)
    monkeypatch.setattr(fa.requests, "patch", patch)

    fa.install_collector_on_new_orgs(None)

    (post_call,) = post.call_args_list
    assert "/organizations/new-org/installations" in post_call.args[0]
    assert post_call.kwargs["json"] == {"client_id": "Iv1.collector", "repository_selection": "all"}
    (patch_call,) = patch.call_args_list
    assert patch_call.args[0].endswith("/organizations/selected/installations/2/repositories")


def test_poison_depth_logged_for_alert(monkeypatch, caplog):
    queue = mock.Mock()
    queue.get_queue_properties.return_value = mock.Mock(approximate_message_count=3)
    monkeypatch.setattr(fa, "_queue", lambda name: queue)
    with caplog.at_level("INFO"):
        fa.report_poison_depth(None)
    assert "sbom-poison-depth=3" in caplog.text


def test_local_secrets_dir_replaces_key_vault(tmp_path, monkeypatch):
    (tmp_path / "dtrack-api-key").write_text("odt_local\n")
    monkeypatch.setenv("LOCAL_SECRETS_DIR", str(tmp_path))
    fa._secret.cache_clear()
    try:
        assert fa._secret("dtrack-api-key") == "odt_local"
        with pytest.raises(ResourceNotFoundError):  # sync_dtrack_acl relies on this to skip
            fa._secret("dtrack-acl-key")
    finally:
        fa._secret.cache_clear()


def test_storage_uses_connection_string_when_set(monkeypatch):
    cls = mock.Mock()
    monkeypatch.setenv("SbomStorage", "UseDevelopmentStorage=true")
    fa._storage(cls, "queue", queue_name="q")
    cls.from_connection_string.assert_called_once_with("UseDevelopmentStorage=true", queue_name="q")
    monkeypatch.delenv("SbomStorage")
    fa._storage(cls, "queue", queue_name="q")
    cls.assert_called_once_with("https://stsbomtest.queue.core.windows.net", credential=fa.CRED, queue_name="q")
