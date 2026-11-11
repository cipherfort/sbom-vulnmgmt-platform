# Local proof of concept

Runs the real collector code on your machine, against real GitHub, with Dependency-Track and an Azure Storage emulator (Azurite) in Docker. You don't need Azure or approvals.

What it proves, before any Azure work:

- **The App's SBOM rate limit.** `generate-report` has its own `dependency_sbom` bucket: 100 an hour per App installation, measured on 1 Nov 2026. `ratelimit` shows what your installation gets.
- **The async SBOM API end to end:** `generate-report`, polling, then the download, on your own repos.
- **The conversion into Dependency-Track:** projects named `<org>/<repo>`, under the org's parent collection project.

## Prerequisites

- Docker with at least **6 GB** of memory and **15 GB of free disk** in Docker Desktop. Dependency-Track takes 4–5 GB of memory, and its vulnerability databases reached about 10 GB of disk on the first day. A full Docker disk stops its database, and every login then fails with a 500 error.
- The collector's Python environment:
  ```bash
  cd sbom-collector && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
  ```

## 1. Create a test GitHub App

Use a separate test App, so the production `cps-sbom-collector` key never leaves Key Vault. It is set up the same way ([deployment runbook](../docs/deployment-runbook.md), step 6).

1. Go to Org → Settings → Developer settings → GitHub Apps → **New GitHub App**.
   - Name: `cps-sbom-collector-poc`. Homepage: any URL. Untick **Webhook → Active**.
   - Repository permissions:
     - **Contents:** read
     - **Metadata:** read
   - Where can it be installed: **Only on this account**.
2. Note the **App ID**.
3. Generate a private key and save it:
   ```bash
   mkdir -p poc/secrets && mv ~/Downloads/<app>.*.private-key.pem poc/secrets/github-app-private-key
   chmod 600 poc/secrets/github-app-private-key
   ```
   `poc/secrets/` is git-ignored. Delete the key from the App when you're done.
4. Install the App on the org. Start with **Only select repositories** and a handful of repos, so that `enumerate` stays small.

## 2. Start Dependency-Track and Azurite

```bash
docker compose -f poc/docker-compose.yml up -d
cp sbom-collector/local.settings.json.example sbom-collector/local.settings.json
# Set GITHUB_APP_ID in sbom-collector/local.settings.json
```

Dependency-Track takes a minute or two to start the first time.

## 3. Set up Dependency-Track

```bash
export GITHUB_ADVISORIES_TOKEN=$(gh auth token)   # optional: turns on the GitHub Advisories source
sbom-collector/.venv/bin/python poc/poc.py dt-init --org <your-org>
```

This does what an admin does by hand in production:

1. Changes the default `admin` password. The new one is saved in `poc/secrets/dtrack-admin-password`.
2. Creates an admin API key.
3. Runs `ops/dtrack_admin.py bootstrap`, with the API keys written to `poc/secrets/` instead of Key Vault.
4. Runs `onboard-org` for each `--org`.

It is safe to re-run.

## 4. Measure the rate limit

```bash
sbom-collector/.venv/bin/python poc/poc.py ratelimit <your-org> --probe <a-repo>
```

The output shows every rate-limit bucket the installation token has, and the `x-ratelimit-*` headers from one `generate-report` call. The result is saved to `poc/out/ratelimit-<org>.json`.

## 5. Collect

```bash
sbom-collector/.venv/bin/python poc/poc.py collect <org>/<repo> <org>/<repo2> ...
```

The runner does what the Functions host does:

- Queues the repos.
- Runs `collect_sbom` on each message, re-queueing while GitHub builds the SBOM.
- Retries failures up to 5 times, then moves the message to `sbom-work-poison`.

It then prints the status of each repo. Ctrl-C is safe; `poc.py drain` picks up where it stopped.

Then:

- Open http://localhost:8080 and sign in as `admin` with the saved password. You should see `<org>`, with `<org>/<repo>` under it.
- Compare one repo by hand against GitHub → Insights → Dependency graph.

`poc.py enumerate` runs the nightly enumeration: **every repo the App can see**, in every org it's installed on. Use it once the App's repository list is the size you want to test.

## What's different from Azure

| Here | In Azure |
|---|---|
| Secrets are files in `poc/secrets/` (`LOCAL_SECRETS_DIR`) | Key Vault, through the managed identity |
| Azurite, with a connection string in `SbomStorage` | `stsbom<env>` through the managed identity; no connection string |
| `poc.py` runs one message at a time | The Functions host runs up to 4 instances × 8 messages |
| Status lines go to the terminal | `sbom-result` lines in Application Insights |
| Dependency-Track on H2, no OIDC | Postgres; Entra sign-in |
| Test App | `cps-sbom-collector` |

The vulnerability sources need time to fill. NVD in particular can take hours without an NVD API key. Until they do, components show up but most vulnerabilities don't.

**Optional:** you can also run the real Functions host with `func start` in `sbom-collector/`. It uses the same `local.settings.json`, with a Python 3.11 virtualenv and Azure Functions Core Tools 4. To trigger a timer function by hand:

```bash
curl -X POST localhost:7071/admin/functions/enumerate_repos -H 'Content-Type: application/json' -d '{}'
```

This path hasn't been tested yet.

## Reset

```bash
docker compose -f poc/docker-compose.yml down -v && rm -rf poc/out poc/secrets/dtrack-*
```
