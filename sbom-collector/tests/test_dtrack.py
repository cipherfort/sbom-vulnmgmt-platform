from unittest import mock

import pytest
from conftest import Resp

from dtrack import DependencyTrack


@pytest.fixture
def dt():
    client = DependencyTrack("https://dtrack.test/", "key")
    client.session = mock.Mock()
    return client


def calls(dt):
    base = "https://dtrack.test/api/v1/"
    return [(c.args[0], c.args[1].removeprefix(base)) for c in dt.session.request.call_args_list]


def test_parent_found_ignores_versioned_children(dt):
    dt.session.request.side_effect = [Resp(200, [{"name": "cps", "version": "main", "uuid": "child"},
                                                 {"name": "cps", "uuid": "parent"}])]
    assert dt.ensure_parent("cps") == "parent"


def test_parent_created_as_collection_project(dt):
    dt.session.request.side_effect = [Resp(200, []), Resp(201, {"uuid": "new"})]
    assert dt.ensure_parent("cps") == "new"
    assert calls(dt)[-1] == ("PUT", "project")
    assert dt.session.request.call_args.kwargs["json"]["collectionLogic"] == "AGGREGATE_DIRECT_CHILDREN"


def test_parent_create_race(dt):
    dt.session.request.side_effect = [Resp(200, []), Resp(409), Resp(200, [{"name": "cps", "uuid": "theirs"}])]
    assert dt.ensure_parent("cps") == "theirs"


def test_parent_invisible_under_acl_is_explained(dt):
    dt.session.request.side_effect = [Resp(200, []), Resp(409), Resp(200, []), Resp(409)]
    with pytest.raises(RuntimeError, match="not visible to this API key"):
        dt.ensure_parent("cps")


def test_upload_uses_parent_uuid(dt):
    dt.session.request.return_value = Resp(200, {"token": "t"})
    dt.upload_bom("cps/svc", "main", "parent-uuid", "Ym9t")
    body = dt.session.request.call_args.kwargs["json"]
    assert body == {"projectName": "cps/svc", "projectVersion": "main", "autoCreate": True,
                    "parentUUID": "parent-uuid", "bom": "Ym9t"}


def test_paged_follows_total_count(dt):
    dt.session.request.side_effect = [Resp(200, [1, 2], headers={"X-Total-Count": "3"}),
                                      Resp(200, [3], headers={"X-Total-Count": "3"})]
    assert list(dt.paged("project", size=2)) == [1, 2, 3]


def test_sync_acl_maps_org_team_to_parent_and_children(dt):
    teams = [{"name": "sg-sbom-org-cps", "uuid": "t-cps"}, {"name": "bom-uploader", "uuid": "t-up"},
             {"name": "ci-uploader", "uuid": "t-ci"}]
    projects = [{"name": "cps", "uuid": "p-cps", "collectionLogic": "AGGREGATE_DIRECT_CHILDREN"},
                {"name": "sandbox", "uuid": "p-sb", "collectionLogic": "AGGREGATE_DIRECT_CHILDREN"},
                {"name": "legacy-app", "uuid": "p-legacy", "collectionLogic": "NONE"}]
    children = [{"name": "cps/svc", "version": "main", "uuid": "c1"},
                {"name": "cps/svc/terraform", "version": "main", "uuid": "c2"}]
    acl = []

    def request(method, url, **kw):
        path = url.removeprefix("https://dtrack.test/api/v1/")
        if path == "team":
            return Resp(200, teams)
        if path == "project":
            return Resp(200, projects, headers={"X-Total-Count": "3"})
        if path == "project/p-cps/children":
            return Resp(200, children, headers={"X-Total-Count": "2"})
        if path == "acl/mapping":
            pair = (kw["json"]["team"], kw["json"]["project"])
            acl.append(pair)
            return Resp(409 if pair == ("t-cps", "c1") else 200)
        raise AssertionError(path)

    dt.session.request.side_effect = request
    granted, missing = dt.sync_acl()

    assert missing == ["sandbox"]  # parent exists, org not onboarded yet
    assert set(acl) == {("t-cps", "p-cps"), ("t-up", "p-cps"), ("t-ci", "p-cps"), ("t-cps", "c1"), ("t-cps", "c2")}
    assert granted == 4  # c1 was already mapped
