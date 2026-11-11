# Deployment runbook

This runbook takes you from a fresh copy of this repo to a platform that collects every repo in the CPS org each night. Do the steps in order. Each step says who does it, where it runs, the commands, and how to check it worked.

- Why it's built this way: [ADR-0001](adr/0001-team-sbom-platform.md).
- Day-to-day operation once it's running: [how-to-use](how-to-use.md).

| Stage | Steps | Result |
|---|---|---|
| [A. Make the copy yours](#stage-a--make-the-copy-yours) | 1–2 | Repo in your org, pointing at your runner and state storage |
| [B. Azure prerequisites](#stage-b--azure-prerequisites) | 3–5 | State storage, deployer identity, resource group and roles |
| [C. GitHub App and repo settings](#stage-c--github-app-and-repo-settings) | 6–8 | Collector App, dependency graph on, CD secrets |
| [D. Deploy](#stage-d--deploy) | 9–10 | Everything in `rg-sbom-<env>` |
| [E. Secrets and Dependency-Track](#stage-e--secrets-and-dependency-track) | 11–13 | App key in Key Vault, Dependency-Track configured |
| [F. First collection](#stage-f--first-collection) | 14–16 | The org collected; five clean nights |
| [G. Entra sign-in](#stage-g--entra-sign-in) | 17–18 | The team signs in with Entra; local `admin` off |
| [After go-live](#after-go-live) | — | Changes and operations |

Nothing here needs a landing zone, a VNet or a jump box. Every command runs from your own machine.

---

## Before you start

### People

| Who | Needed for steps |
|---|---|
| **Azure subscription Owner**, or Contributor plus User Access Administrator | 3, 4, 5, 11 |
| **Entra admin**: Application Administrator and Groups Administrator. Privileged Role Administrator only for option A in step 17 | 4, 17 |
| **CPS GitHub org owner** | 2, 6, 7 |
| **Admin of the new GitHub repo** | 2, 8, 9, 15 |
| **CPS platform engineer**: runs everything else | all |

### Tools

The Azure CLI (`az`), the GitHub CLI (`gh`), Terraform 1.11.x (`cd.yml` pins 1.11.4), Python 3.11, `git`, `jq`, `curl` and `perl`.

### Values to collect

Fill this in once and save it **outside the repo**. Source it in every shell you use for this runbook. Later steps append to it.

```bash
cat > ~/sbom-deploy.env <<'EOF'
export SUB=<subscription id>
export TENANT=<Entra tenant id>
export LOCATION=uksouth                    # uksouth or ukwest (Terraform enforces this)
export ENV=prd
export SFX=                                # global_name_suffix: 0-6 lowercase letters/digits, only if a default name is taken
export RG=rg-sbom-$ENV
export KV=kv-sbom-$ENV$SFX
export FUNC=func-sbom-$ENV$SFX
export STATE_RG=rg-tfstate-sbom
export STATE_SA=<globally unique storage account name, 3-24 lowercase letters/digits>
export GH_REPO=<cps-org>/<repo-name>       # where the copy will live
export RUNNER=ubuntu-latest                # or your org's runner label
export ORG=<the CPS GitHub org login, exactly as GitHub spells it>
EOF
source ~/sbom-deploy.env
```

---

## Stage A — Make the copy yours

### Step 1 — Point the code at your repo, runner and state storage

**Who:** platform engineer. **Where:** your machine, in a clone of the source repo.

Three things in the code are specific to where this repo was built:

| What | Where | If left unchanged |
|---|---|---|
| Repo path `sg-cloud-platform/cps-security-platform-infra` | Workflow header comments | Harmless, but misleading |
| Runner label `cps-ubuntu-latest-private` | `cd.yml`, `sbom-collector-ci.yml`, `sbom-scan.yml`, `image-scan.yml`, `container-sbom.yml`, `release-sbom-attest.yml`, `.github/actionlint.yaml` | Jobs queue forever if your org has no runner with that label |
| State backend `rg-tfstate-security-platform` / `stsecplatstate001` | `versions.tf` | `terraform init` fails or writes to someone else's account |

Any runner with internet access works. Every endpoint the jobs reach (Azure, Key Vault, the Dependency-Track API) is public. `ubuntu-latest` is fine unless your org requires self-hosted runners.

```bash
source ~/sbom-deploy.env
git switch feature/team-sbom-platform
git switch -c deploy/$ENV

EXCLUDE=':!docs/deployment-runbook.md'
git grep -l 'sg-cloud-platform/cps-security-platform-infra' -- . "$EXCLUDE" \
  | xargs perl -pi -e "s#sg-cloud-platform/cps-security-platform-infra#$GH_REPO#g"
git grep -l 'cps-ubuntu-latest-private' -- . "$EXCLUDE" \
  | xargs perl -pi -e "s#cps-ubuntu-latest-private#$RUNNER#g"
perl -pi -e "s#\"rg-tfstate-security-platform\"#\"$STATE_RG\"#; s#\"stsecplatstate001\"#\"$STATE_SA\"#" versions.tf

git diff --stat
git commit -am "Configure for $GH_REPO"
```

**Check:** `git grep -n -e stsecplatstate001 -e cps-ubuntu-latest-private -- . "$EXCLUDE"` prints nothing. If `$RUNNER` is `ubuntu-latest`, also remove that label from `.github/actionlint.yaml`.

### Step 2 — Create the repo and push

**Who:** org owner or repo admin. **Where:** your machine.

Push with git. **Don't copy the folder or a zip of it.** `poc/secrets/` (real API keys and a GitHub App private key) and `sbom-collector/local.settings.json` are git-ignored, so git leaves them behind. A file copy would take them along.

```bash
gh repo create $GH_REPO --internal --description "CPS SBOM platform"
git remote add team https://github.com/$GH_REPO.git
git push team deploy/$ENV:main

# Let the org's other repos call sbom-scan.yml and the other reusable workflows.
gh api -X PUT repos/$GH_REPO/actions/permissions/access -f access_level=organization
```

The push to `main` starts `cd.yml`. That run fails at Azure login because there are no secrets yet. This is expected and changes nothing.

**Check:** `gh api repos/$GH_REPO/contents/poc --jq '.[].name'` lists no `secrets` entry. Protect `main` (Settings → Branches) so changes go through pull requests.

---

## Stage B — Azure prerequisites

### Step 3 — Resource providers and Terraform state storage

**Who:** subscription Owner. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
az account set -s $SUB

for ns in Microsoft.App Microsoft.Web Microsoft.KeyVault Microsoft.Storage Microsoft.DBforPostgreSQL \
          Microsoft.Insights Microsoft.OperationalInsights; do
  az provider register --namespace $ns
done

az group create -n $STATE_RG -l $LOCATION
az storage account create -n $STATE_SA -g $STATE_RG -l $LOCATION \
  --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false
az storage account blob-service-properties update -n $STATE_SA -g $STATE_RG --enable-versioning true
az storage container-rm create --storage-account $STATE_SA -g $STATE_RG -n terraform-state
```

The backend signs in with Entra ID (`use_azuread_auth`), so shared keys can stay off. Versioning lets you recover an earlier state file.

**Check:** `az provider show -n Microsoft.App --query registrationState -o tsv` prints `Registered`.

**UI alternative:** Subscription → Resource providers to register each one. Storage accounts → Create, with *Allow storage account key access* off on the Advanced tab, then Data protection → *Enable versioning for blobs*.

### Step 4 — Deployer identity for GitHub Actions

**Who:** Entra admin (to create the app) and platform engineer. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
DEPLOYER_APP_ID=$(az ad app create --display-name sp-sbom-platform-github-actions --query appId -o tsv)
DEPLOYER_SP=$(az ad sp create --id $DEPLOYER_APP_ID --query id -o tsv)

az ad app federated-credential create --id $DEPLOYER_APP_ID --parameters "{
  \"name\": \"sbom-cd-security-platform\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$GH_REPO:environment:security-platform\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"

echo "export DEPLOYER_APP_ID=$DEPLOYER_APP_ID DEPLOYER_SP=$DEPLOYER_SP" >> ~/sbom-deploy.env
```

The subject names the **environment**, not the branch. Both `cd.yml` jobs run in the `security-platform` environment, and GitHub then issues `repo:<org>/<repo>:environment:security-platform` as the token subject. A `ref:refs/heads/main` credential would never match. Branch control comes from the environment's reviewers (step 8) and from protecting `main`.

**UI alternative:** Entra ID → App registrations → New registration. Then Certificates & secrets → Federated credentials → Add → *GitHub Actions deploying Azure resources*, entity type **Environment**, name `security-platform`.

### Step 5 — Resource group and deployer roles

**Who:** subscription Owner. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
# Works in bash and zsh (zsh does not word-split an unquoted $VAR)
grant() { az role assignment create --assignee-object-id $DEPLOYER_SP --assignee-principal-type ServicePrincipal "$@"; }

az group create -n $RG -l $LOCATION
RG_ID=$(az group show -n $RG --query id -o tsv)

grant --role Contributor --scope $RG_ID
# Terraform creates role assignments. This lets it grant only the roles the platform uses.
grant --role "Role Based Access Control Administrator" --scope $RG_ID \
  --condition-version 2.0 --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {00482a5a-887f-4fb3-b363-3b7fe8e74483, 4633458b-17de-408a-b874-0445c86b69e6, b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3, 3913510d-42f4-4e42-8a64-420c390055eb}))"

# Terraform state
grant --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n $STATE_SA -g $STATE_RG --query id -o tsv)
```

The conditioned GUIDs are, in order: Key Vault Administrator, Key Vault Secrets User, Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor and Monitoring Metrics Publisher.

**Check:** `az role assignment list --assignee $DEPLOYER_SP --all -o table` shows the three assignments.

**UI alternative:** the resource group → Access control (IAM) → Add role assignment. For Role Based Access Control Administrator, pick *Allow user to only assign selected roles to selected principals* on the Conditions tab and select the six roles above.

---

## Stage C — GitHub App and repo settings

### Step 6 — Create the collector GitHub App

**Who:** CPS GitHub org owner. **Where:** browser.

1. Go to Org → Settings → Developer settings → GitHub Apps → **New GitHub App**.
   - Name `cps-sbom-collector`. Use any homepage URL. Untick **Webhook → Active**.
   - Repository permissions: **Contents** read and **Metadata** read. Nothing else.
   - Where can this App be installed: **Only on this account**.
2. Note the **App ID** and record it:
   ```bash
   echo "export GITHUB_APP_ID=<app id>" >> ~/sbom-deploy.env
   ```
3. **Generate a private key.** The Key Vault doesn't exist until step 9, so keep the `.pem` somewhere safe until step 11, then delete it.
4. Install the App on the org with **All repositories**. With *Only select repositories*, new repos are never collected.

Also create a **read-only GitHub token** for Dependency-Track's GitHub Advisories mirror: a fine-grained token with public-repository read only, ideally owned by a service account. Step 12 uses it.

### Step 7 — Turn on the dependency graph for every repo

**Who:** CPS GitHub org owner or security manager. **Where:** your machine, in the repo.

```bash
source ~/sbom-deploy.env
gh auth refresh -h github.com -s write:org
scripts/github/security-config.sh --org $ORG
```

This creates the org configuration `cps-sbom-baseline`. It turns on the dependency graph, automatic dependency submission and Dependabot alerts, and leaves paid features `not_set`. The script attaches it to every repo not already on another configuration, and makes it the default for new repos. It lists the existing configurations first. Add the same three settings to those configurations, or re-run with `--include-configured` to replace them.

**Check:** in any repo, Insights → Dependency graph shows dependencies.

**UI alternative:** Org → Settings → Code security → Configurations → **New configuration**. Set Dependency graph, Automatic dependency submission and Dependabot alerts to Enabled, leave the rest Not set, then *Apply to* → All repositories, and *Use as default* for new repositories.

### Step 8 — Terraform variables, repo secrets and environment

**Who:** admin of the new repo. **Where:** your machine.

Write `terraform.tfvars.json`. It's git-ignored. **Keep a copy outside the repo**: GitHub secrets can't be read back, and you'll edit this file again in step 17.

```bash
source ~/sbom-deploy.env
cat > terraform.tfvars.json <<JSON
{
  "environment": "$ENV",
  "global_name_suffix": "$SFX",
  "github_app_id": "$GITHUB_APP_ID",
  "alert_email": "<team mailbox for collector alerts>",
  "allowed_ip_ranges": ["<office or VPN egress CIDR>"]
}
JSON
jq . terraform.tfvars.json > /dev/null && echo valid
cp terraform.tfvars.json ~/sbom-terraform.tfvars.json
```

`allowed_ip_ranges` limits who can open the Dependency-Track UI. Use an empty list to allow everyone. [`terraform.tfvars.example`](../terraform.tfvars.example) explains every variable.

Optionally, validate locally. This needs no Azure access:

```bash
terraform init -backend=false && terraform validate && terraform test
```

Set the secrets, the variable and the environment:

```bash
gh secret set AZURE_CLIENT_ID       -R $GH_REPO --body $DEPLOYER_APP_ID
gh secret set AZURE_TENANT_ID       -R $GH_REPO --body $TENANT
gh secret set AZURE_SUBSCRIPTION_ID -R $GH_REPO --body $SUB
gh secret set TF_VARS_JSON          -R $GH_REPO < terraform.tfvars.json
gh variable set FUNCTION_APP_NAME   -R $GH_REPO --body $FUNC

# Required reviewers for every apply. For a team, use {"type": "Team", "id": <team id>}.
gh api -X PUT repos/$GH_REPO/environments/security-platform --input - <<JSON
{"reviewers": [{"type": "User", "id": $(gh api users/<reviewer-login> --jq .id)}]}
JSON
```

`FUNCTION_APP_NAME` is set now from the known name, so the first apply can deploy the collector code in the same run.

**Check:** `gh secret list -R $GH_REPO` shows four secrets.

**UI alternative:** the repo → Settings → Secrets and variables → Actions for the secrets and the variable; Settings → Environments → New environment `security-platform` → Required reviewers.

---

## Stage D — Deploy

### Step 9 — Plan, then apply

**Who:** platform engineer, plus an environment reviewer. **Where:** your machine (the runner does the work).

```bash
source ~/sbom-deploy.env
gh workflow run cd.yml -R $GH_REPO -f action=plan
sleep 10; RUN=$(gh run list -R $GH_REPO -w cd.yml -L 1 --json databaseId -q '.[0].databaseId')
# A reviewer approves the run: Actions → the run → Review deployments
gh run watch $RUN -R $GH_REPO
gh run view $RUN -R $GH_REPO --log | grep -E 'Plan:|Error'
```

Read the plan. It should create 38 resources and destroy nothing. Then apply:

```bash
gh workflow run cd.yml -R $GH_REPO -f action=apply
sleep 10; RUN=$(gh run list -R $GH_REPO -w cd.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run watch $RUN -R $GH_REPO
```

The run asks for approval twice: once for `terraform`, once for `collector-deploy`. Postgres and the Container Apps environment are the slow parts, so allow 20–40 minutes.

If the plan fails because a name is taken (the Key Vault, storage accounts and Postgres server need globally unique names):
1. Set `SFX` in `~/sbom-deploy.env`.
2. Add `"global_name_suffix"` to the tfvars and update `TF_VARS_JSON`.
3. Re-set `FUNCTION_APP_NAME`.
4. Run the plan again.

**UI alternative:** Actions → *SBOM Platform CD* → Run workflow, choose `plan` or `apply`.

### Step 10 — Check the deployment and get the addresses

**Who:** platform engineer. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
az resource list -g $RG --query "[].{name:name, type:type}" -o table

fqdn() { az containerapp show -g $RG -n $1 --query properties.configuration.ingress.fqdn -o tsv; }
cat >> ~/sbom-deploy.env <<EOF
export DT_UI=https://$(fqdn ca-dtrack-ui) DT_API=https://$(fqdn ca-dtrack-api)
EOF
source ~/sbom-deploy.env
echo "UI: $DT_UI  API: $DT_API"

az functionapp show -g $RG -n $FUNC --query "{state:properties.state, host:properties.defaultHostName}" -o table
```

**Check:** `curl -s $DT_API/api/version` returns JSON with `"version":"4.14.6"`. The first start creates the database schema and can take several minutes. Then open `$DT_UI` from an address in `allowed_ip_ranges`: you should get the login page.

**UI alternative:** the resource group in the portal. Each container app's Overview shows its *Application Url*.

---

## Stage E — Secrets and Dependency-Track

### Step 11 — Key Vault access and the App private key

**Who:** subscription Owner grants the role; platform engineer stores the key. **Where:** anywhere with `az`.

The deployer can't grant this role; its condition doesn't allow it. Grant it to a group of CPS platform admins rather than to individuals. Use PIM if you have it.

```bash
source ~/sbom-deploy.env
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
az role assignment create --assignee-object-id <platform-admins-group-object-id> --assignee-principal-type Group \
  --role "Key Vault Secrets Officer" --scope $KV_ID

# Wait a few minutes for the role to apply, then:
az keyvault secret set --vault-name $KV -n github-app-private-key --file <path-to>.private-key.pem --output none
```

Delete the `.pem`, including any copy in Downloads.

**Check:** `az keyvault secret list --vault-name $KV --query "[].name" -o tsv` lists `github-app-private-key` and `postgres-admin-password`.

**UI alternative:** the vault → Access control (IAM) for the role; Objects → Secrets → Generate/Import, pasting the whole `.pem` (including the BEGIN and END lines) as the value.

### Step 12 — Set up Dependency-Track

**Who:** platform engineer. **Where:** your machine, in the repo, signed in with `az login`. You need the Secrets Officer role from step 11, because the script writes to Key Vault as you.

```bash
source ~/sbom-deploy.env
cd sbom-collector
python3.11 -m venv .venv && .venv/bin/pip install -q -r requirements.txt

export DTRACK_URL=$DT_API KV_URL=https://$KV.vault.azure.net/
read -rs GITHUB_ADVISORIES_TOKEN && export GITHUB_ADVISORIES_TOKEN    # the read-only token from step 6
.venv/bin/python ops/first_setup.py
cd ..
```

[`ops/first_setup.py`](../sbom-collector/ops/first_setup.py) does what an admin would otherwise do in the browser:
1. Changes the default `admin` / `admin` password to a random one and stores it in Key Vault as `dtrack-admin-password`.
2. Creates a temporary Administrators API key. Step 18 deletes it.
3. Runs `dtrack_admin.py bootstrap`:
   - turns on the NVD, OSV and GitHub Advisories sources;
   - creates the teams `bom-uploader`, `ci-uploader`, `sg-sbom-cps-admins` and `sg-sbom-cps-users`;
   - writes the uploader keys to Key Vault as `dtrack-api-key` and `dtrack-ci-api-key`;
   - adds the `CPS restricted` licence group and the three starter policies.
4. Runs `dtrack_admin.py onboard-org $ORG`, which creates the org's parent collection project. Run it again by hand with `--teams-webhook <url>` to send new vulnerabilities and policy violations to a Teams channel.

It is safe to re-run.

**Check:**
- `az keyvault secret list --vault-name $KV --query "[].name" -o tsv` now also lists `dtrack-admin-password`, `dtrack-api-key` and `dtrack-ci-api-key`.
- Sign in to `$DT_UI` as `admin` with the password from Key Vault. Administration → Teams shows the four teams, Policy Management shows three policies, and Projects shows `$ORG`.

**UI alternative:** sign in as `admin` / `admin` and change the password when asked. Create the API key under Administration → Access Management → Teams → Administrators → API Keys. Then run `dtrack_admin.py bootstrap --key-vault-url $KV_URL` and `onboard-org $ORG` with `DTRACK_ADMIN_API_KEY` set to that key. The team, policy and source setup has no sensible UI path; use the script.

### Step 13 — Restart the collector and the Dependency-Track API

**Who:** platform engineer. **Where:** anywhere with `az`.

The collector caches secrets for the life of an instance, so restart it to pick up the new keys. Dependency-Track schedules its OSV mirror at startup, which was before `bootstrap` chose the ecosystems. Until it restarts, the log says `Google OSV mirroring is disabled. No ecosystem selected` and OSV stays off for 24 hours.

```bash
source ~/sbom-deploy.env
az functionapp restart -g $RG -n $FUNC
REV=$(az containerapp revision list -g $RG -n ca-dtrack-api --query "[?properties.active].name | [0]" -o tsv)
az containerapp revision restart -g $RG -n ca-dtrack-api --revision $REV
```

The first NVD and OSV downloads take an hour or more. Projects uploaded before they finish show no vulnerabilities until the next analysis, so judge the first collection's vulnerability counts the next day.

**UI alternative:** the Function App → Overview → Restart; `ca-dtrack-api` → Revisions and replicas → the active revision → Restart.

---

## Stage F — First collection

### Step 14 — Run the first collection

**Who:** platform engineer. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
FUNC_HOST=$(az functionapp show -g $RG -n $FUNC --query properties.defaultHostName -o tsv)  # top-level defaultHostName is null on Flex Consumption
MASTER=$(az functionapp keys list -g $RG -n $FUNC --query masterKey -o tsv)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://$FUNC_HOST/admin/functions/enumerate_repos" \
  -H "x-functions-key: $MASTER" -H 'Content-Type: application/json' -d '{}'
```

Expect `202`. Each repo's outcome is logged as an `sbom-result` line a few minutes later. Run [`collector-status.kql`](../sbom-collector/kql/collector-status.kql) in Application Insights `appi-sbom-<env>` → Logs, or from the CLI:

```bash
az monitor app-insights query -g $RG --app appi-sbom-$ENV --analytics-query "$(cat sbom-collector/kql/collector-status.kql)" -o table
```

GitHub allows **100 SBOMs an hour per org**, so an org of more than 100 repos takes hours to collect. Throttled jobs wait on the queue; that's expected. The statuses are explained in [how-to-use §5](how-to-use.md#5-collector-statuses).

**Check:**
- Repos show `ok`, or `no-dependency-graph` for repos with no manifests.
- In Dependency-Track, `$ORG` has `$ORG/<repo>` children.
- For three repos, compare the component counts with GitHub → Insights → Dependency graph.

**UI alternative:** the Function App → Functions → `enumerate_repos` → Code + Test → Test/Run.

### Step 15 — Test the Terraform path (`sbom-scan.yml`)

**Who:** admin of the new repo. **Where:** anywhere with `az` and `gh`.

```bash
source ~/sbom-deploy.env
gh variable set DEPENDENCY_TRACK_URL -R $GH_REPO --body $DT_API
az keyvault secret show --vault-name $KV -n dtrack-ci-api-key --query value -o tsv \
  | gh secret set DEPENDENCY_TRACK_API_KEY -R $GH_REPO
gh workflow run test-sbom-scan.yml -R $GH_REPO
```

**Check:** project `$ORG/<repo>/terraform` appears under the parent `$ORG`.

To let every Terraform repo in the org use the scan, set both values once at org level:

```bash
gh variable set DEPENDENCY_TRACK_URL --org $ORG --visibility all --body $DT_API
az keyvault secret show --vault-name $KV -n dtrack-ci-api-key --query value -o tsv \
  | gh secret set DEPENDENCY_TRACK_API_KEY --org $ORG --visibility all
```

### Step 16 — Five clean nights

**Who:** platform engineer. **Where:** Application Insights and the alert mailbox.

Collection now runs by itself: `enumerate_repos` at 02:00 UTC, and `report_poison_depth` every 15 minutes.

Wait for **five consecutive nights** with:
- no `sbom-poison-queue-not-empty` alert;
- no `sbom-enumerate-not-succeeded` alert;
- `collector-status.kql` showing steady counts, with nothing in `error` or `timeout`.

---

## Stage G — Entra sign-in

### Step 17 — Groups and the Dependency-Track app registration

**Who:** Entra admin. **Where:** anywhere with `az`.

There are two options:

- **Option B, by hand (recommended).** You create the groups and the app with the commands below.
- **Option A, Terraform (`manage_entra = true`).** Terraform creates them, but the CI identity then needs `AppRoleAssignment.ReadWrite.All`, which lets it grant itself any permission in the tenant. Most government tenants won't allow that on a pipeline identity.

The group names must be exactly `sg-sbom-cps-admins` and `sg-sbom-cps-users`. Step 12 mapped Dependency-Track teams to those names.

**Option B — by hand**

```bash
source ~/sbom-deploy.env
for g in sg-sbom-cps-admins sg-sbom-cps-users; do az ad group create --display-name $g --mail-nickname $g --output none; done

DT_APP=$(az ad app create --display-name "Dependency-Track (sbom-$ENV)" --sign-in-audience AzureADMyOrg --query appId -o tsv)
DT_APP_OBJ=$(az ad app show --id $DT_APP --query id -o tsv)

# SPA callback, and a groups claim that carries only assigned groups, as display names
cat > "${TMPDIR:-/tmp}/dt-app.json" <<JSON
{
  "spa": {"redirectUris": ["$DT_UI/static/oidc-callback.html"]},
  "groupMembershipClaims": "ApplicationGroup",
  "optionalClaims": {
    "idToken":     [{"name": "groups", "additionalProperties": ["cloud_displayname"]}],
    "accessToken": [{"name": "groups", "additionalProperties": ["cloud_displayname"]}]
  }
}
JSON
az rest --method PATCH --uri https://graph.microsoft.com/v1.0/applications/$DT_APP_OBJ \
  --headers Content-Type=application/json --body @"${TMPDIR:-/tmp}/dt-app.json"

# Only assigned groups can sign in
DT_SP=$(az ad sp create --id $DT_APP --query id -o tsv)
az rest --method PATCH --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP \
  --headers Content-Type=application/json --body '{"appRoleAssignmentRequired": true}'
for g in sg-sbom-cps-admins sg-sbom-cps-users; do
  GID=$(az ad group show --group $g --query id -o tsv)
  az rest --method POST --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP/appRoleAssignedTo \
    --headers Content-Type=application/json \
    --body "{\"principalId\": \"$GID\", \"resourceId\": \"$DT_SP\", \"appRoleId\": \"00000000-0000-0000-0000-000000000000\"}" \
    --output none
done

echo "export DT_APP=$DT_APP DT_SP=$DT_SP" >> ~/sbom-deploy.env
```

Then add `"dtrack_oidc_client_id": "<DT_APP>"` to `~/sbom-terraform.tfvars.json`. Update `TF_VARS_JSON` from it and apply, as in step 9:

```bash
gh secret set TF_VARS_JSON -R $GH_REPO < ~/sbom-terraform.tfvars.json
gh workflow run cd.yml -R $GH_REPO -f action=apply
```

**UI alternative for option B:** Entra ID → Groups → New group, twice. Then App registrations → New registration:
- Authentication → *Single-page application* with the redirect URI above.
- Token configuration → Add groups claim → *Groups assigned to the application*, emitted as **Cloud-only group display names**.
- Enterprise applications → the app → Properties → *Assignment required* = Yes.
- Users and groups → add both groups.

**Option A — Terraform**

Give the deployer these Microsoft Graph application permissions. The function below looks up their IDs by name. Granting admin consent needs a Privileged Role Administrator:

```bash
GRAPH=00000003-0000-0000-c000-000000000000
perm() { az ad sp show --id $GRAPH --query "appRoles[?value=='$1'].id | [0]" -o tsv; }
az ad app permission add --id $DEPLOYER_APP_ID --api $GRAPH --api-permissions \
  "$(perm Group.ReadWrite.All)=Role" "$(perm Application.ReadWrite.OwnedBy)=Role" \
  "$(perm AppRoleAssignment.ReadWrite.All)=Role" "$(perm Application.Read.All)=Role"
az ad app permission admin-consent --id $DEPLOYER_APP_ID
```

Then add `"manage_entra": true` to the tfvars, update `TF_VARS_JSON` and apply.

**Both options:** add the people:

```bash
az ad group member add --group sg-sbom-cps-admins --member-id $(az ad user show --id <upn> --query id -o tsv)
```

Put the platform admins in `sg-sbom-cps-admins`, and everyone else on the team who triages findings in `sg-sbom-cps-users`.

### Step 18 — Switch to Entra sign-in

**Who:** a member of `sg-sbom-cps-admins`. **Where:** browser.

1. Open `$DT_UI` and sign in with **OpenID**. You should see Administration and every project.
2. Ask a member of `sg-sbom-cps-users` to sign in. They should see every project, but no Administration menu.
3. Suspend the local admin: Administration → Access Management → Managed Users → `admin` → **Suspended**. The password stays in Key Vault for recovery.
4. Delete the temporary API key from step 12: Teams → Administrators → API Keys.

---

## After go-live

- **Changing the platform:** open a pull request, merge it to `main`, and `cd.yml` runs plan and apply after a reviewer approves. Collector code changes deploy in the same run. Keep `~/sbom-terraform.tfvars.json` as the source for `TF_VARS_JSON`.
- **Day to day:** [how-to-use](how-to-use.md) covers using Dependency-Track, rotating credentials (§7) and the failure runbook (§8).
- **The old stack:** if the DefectDojo platform from `main` (`rg-security-platform`) was ever deployed, delete that resource group and its `security-platform.tfstate` state blob once this platform is in use.

## Tearing it down

```bash
source ~/sbom-deploy.env
terraform init && terraform destroy          # with the same tfvars, as the deployer or an Owner
# Application Insights creates this action group itself, so Terraform doesn't remove it
az monitor action-group delete -g $RG -n "Application Insights Smart Detection"
```

The Key Vault is soft-deleted with purge protection, so its name is reserved for 90 days. A redeploy with the same name recovers it automatically (`recover_soft_deleted_key_vaults`).

## Troubleshooting the first deployment

| Symptom | Cause | Fix |
|---|---|---|
| `cd.yml` jobs stay *Queued* | No runner with the `$RUNNER` label | Check the label from step 1 matches a runner available to the repo |
| `AADSTS700213` / `AADSTS70021` at Azure login | The federated credential subject doesn't match | It must be `repo:<org>/<repo>:environment:security-platform`, matching `$GH_REPO` exactly (step 4) |
| `AuthorizationFailed` creating a role assignment | RBAC Administrator role or its condition missing | Re-run step 5 |
| Plan fails: the storage account, Key Vault or Postgres name is taken | Globally unique names | Set `global_name_suffix` (step 9) |
| `collector-deploy` can't find the app | `FUNCTION_APP_NAME` doesn't match | `gh variable set FUNCTION_APP_NAME --body $FUNC` |
| `Forbidden` from `az keyvault secret set` | No Secrets Officer role yet, or it hasn't applied | Step 11; wait a few minutes after granting |
| Dependency-Track UI returns 403 | Your IP isn't in `allowed_ip_ranges` | Add your egress CIDR to the tfvars and apply (`curl -4 ifconfig.me` shows it) |
| Dependency-Track UI loads but every page fails | The API isn't up yet, or crashed | `curl $DT_API/api/version`; `az containerapp logs show -g $RG -n ca-dtrack-api --tail 100` |
| Host keys fail with 400, or timers never fire | `AzureWebJobsStorage` set to a key-based string | It must be empty (`collector.tf` sets it so); check the Function's Environment variables |
| `enumerate_repos` logs a 401 | Wrong or missing `github-app-private-key` | Re-store the key (step 11), then restart (step 13) |
| Every repo is `no-dependency-graph` | `cps-sbom-baseline` not applied yet, or the App was installed on selected repositories | Step 7; set the installation to All repositories |
