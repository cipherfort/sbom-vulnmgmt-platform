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


def test_parent_invisible_is_explained(dt):
    dt.session.request.side_effect = [Resp(200, []), Resp(409), Resp(200, []), Resp(409)]
    with pytest.raises(RuntimeError, match="not visible to this API key"):
        dt.ensure_parent("cps")


def test_upload_uses_parent_uuid(dt):
    dt.session.request.return_value = Resp(200, {"token": "t"})
    dt.upload_bom("cps/svc", "main", "parent-uuid", "Ym9t")
    body = dt.session.request.call_args.kwargs["json"]
    assert body == {"projectName": "cps/svc", "projectVersion": "main", "autoCreate": True,
                    "parentUUID": "parent-uuid", "bom": "Ym9t"}



def test_session_token_replaces_api_key():
    by_key = DependencyTrack("https://dtrack.test", "key").session.headers
    by_token = DependencyTrack("https://dtrack.test", token="jwt").session.headers
    assert by_key["X-Api-Key"] == "key" and "Authorization" not in by_key
    assert by_token["Authorization"] == "Bearer jwt" and "X-Api-Key" not in by_token
