import json
import os
import pathlib

import pytest

# function_app reads these at import time.
os.environ.setdefault("SBOM_STORAGE_ACCOUNT", "stsbomtest")
os.environ.setdefault("GITHUB_APP_ID", "123456")
os.environ.setdefault("GITHUB_ENTERPRISE", "cps-test")
os.environ.setdefault("KEY_VAULT_URL", "https://kv-sbom-test.vault.azure.net/")
os.environ.setdefault("DTRACK_URL", "https://dtrack.test")

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


@pytest.fixture
def spdx():
    return json.loads((FIXTURES / "github-spdx-actions-setup-python.json").read_text())


class Resp:
    """Just enough of requests.Response for the collector."""

    def __init__(self, status=200, body=None, headers=None, links=None, text=""):
        self.status_code, self._body, self.headers = status, body, headers or {}
        self.links, self.text = links or {}, text

    @property
    def ok(self):
        return self.status_code < 400

    def json(self):
        return self._body

    def raise_for_status(self):
        import requests

        if self.status_code >= 400:
            raise requests.HTTPError(f"HTTP {self.status_code}", response=self)


class Msg:
    def __init__(self, job, dequeue_count=1):
        self._body, self.dequeue_count = json.dumps(job).encode(), dequeue_count

    def get_body(self):
        return self._body
