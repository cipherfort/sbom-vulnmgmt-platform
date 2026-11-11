"""Deployment runbook step 12 without a browser: change Dependency-Track's
default admin password, keep it in Key Vault, create a temporary
Administrators API key, then run dtrack_admin.py bootstrap and onboard-org.
Safe to re-run.

  export DTRACK_URL=https://ca-dtrack-api.<env-domain>
  export KV_URL=https://kv-sbom-prd.vault.azure.net/
  export ORG=<the CPS GitHub org login>
  export GITHUB_ADVISORIES_TOKEN=...   # optional, passed through to bootstrap
  python ops/first_setup.py

Runs as you (az login), so you need Key Vault Secrets Officer on the vault.
"""
import os
import pathlib
import secrets
import subprocess
import sys

import requests
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

API = os.environ["DTRACK_URL"].rstrip("/") + "/api/v1"
KV_URL = os.environ["KV_URL"]
ORG = os.environ["ORG"]
ADMIN = pathlib.Path(__file__).with_name("dtrack_admin.py")
kv = SecretClient(KV_URL, DefaultAzureCredential())

try:
    pw = kv.get_secret("dtrack-admin-password").value or ""
except ResourceNotFoundError:
    pw = ""

if not pw:
    pw = secrets.token_hex(24)
    r = requests.post(f"{API}/user/forceChangePassword", timeout=30, data={
        "username": "admin", "password": "admin", "newPassword": pw, "confirmPassword": pw})
    print("Change default admin password:", r.status_code)
    r.raise_for_status()
    kv.set_secret("dtrack-admin-password", pw)
    print("Stored admin password in Key Vault secret dtrack-admin-password")

login = requests.post(f"{API}/user/login", data={"username": "admin", "password": pw}, timeout=30)
print("Admin login:", login.status_code)
login.raise_for_status()
auth = {"Authorization": f"Bearer {login.text}"}

teams = requests.get(f"{API}/team", headers=auth, timeout=30)
teams.raise_for_status()
admins = next(t for t in teams.json() if t["name"] == "Administrators")
key = requests.put(f"{API}/team/{admins['uuid']}/key", headers=auth, timeout=30)
key.raise_for_status()
print("Temporary Administrators API key created (delete it after Entra sign-in works)")

env = dict(os.environ, DTRACK_ADMIN_API_KEY=key.json()["key"])
for args in (["bootstrap", "--key-vault-url", KV_URL], ["onboard-org", ORG]):
    subprocess.run([sys.executable, str(ADMIN), *args], env=env, check=True)
