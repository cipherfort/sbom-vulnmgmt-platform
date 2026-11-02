# Deployment runbook

This runbook takes you from a fresh copy of this repo to a platform that collects every repo in every org. Do the steps in order. Each step says who does it, where it runs, the commands to run and how to check it worked.

- Why it's built this way: [ADR-0002](../adr/0002-enterprise-sbom-platform.md).
- Phase checklists, gates and open questions: [delivery plan](delivery-plan.md).
- Day-to-day operation once it's running: [how-to-use](../how-to-use.md).

| Stage | Steps | Result |
|---|---|---|
| [A. Make the copy yours](#stage-a--make-the-copy-yours) | 1–2 | Repo in your org, pointing at your runner and state storage |
| [B. Azure prerequisites](#stage-b--azure-prerequisites) | 3–6 | Landing zone ready, state storage, deployer identity and roles |
| [C. GitHub App and repo settings](#stage-c--github-app-and-repo-settings) | 7–9 | Collector App, pilot org on `cps-sbom-baseline`, CD secrets |
| [D. Deploy](#stage-d--deploy) | 10–11 | Everything in `rg-sbom-<env>` |
| [E. Secrets and Dependency-Track](#stage-e--secrets-and-dependency-track) | 12–15 | Keys in Key Vault, Dependency-Track configured, pilot org onboarded |
| [F. First collection (pilot)](#stage-f--first-collection-pilot) | 16–18 | Pilot org collected; five clean nights |
| [G. Entra sign-in](#stage-g--entra-sign-in) | 19–20 | Teams sign in with Entra; local `admin` off |
| [H. Every org](#stage-h--every-org) | 21–24 | Enterprise-wide coverage |
| [After go-live](#after-go-live) | — | Changes, operations, Phase 3 |

---

## Before you start

### People

| Who | Needed for steps |
|---|---|
| **Azure subscription Owner**, or Contributor plus User Access Administrator | 4, 5, 6, 12 |
| **Landing-zone team**: subnets, private DNS, corporate DNS forwarding, the runner's network | 3, 11 |
| **Entra admin**: Application Administrator and Groups Administrator. Privileged Role Administrator only for option A in step 19 | 5, 19, 23 |
| **GitHub enterprise owner** | 7, 8, 21, 22 |
| **Admin of the new GitHub repo** | 2, 9, 10, 17 |
| **CPS platform engineer**: runs everything else | all |

### Tools

The Azure CLI (`az`), the GitHub CLI (`gh`), Terraform 1.11.x (`cd.yml` pins 1.11.4), Python 3.11, `git`, `jq` and `perl`.

### Admin workstation

From step 11 on, several steps reach private endpoints and the internal Dependency-Track. Run those from an **admin workstation**: a jump box in the landing-zone VNet, or a machine on a VPN that routes into it and resolves the landing zone's private DNS. The steps that need one are marked **Where: admin workstation**.

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
export GH_REPO=<team-org>/<repo-name>      # where the copy will live
export RUNNER=<runner label>               # self-hosted runner with a route into the landing-zone VNet
export ENTERPRISE=<GitHub enterprise slug>
export PILOT_ORG=<first GitHub org to collect>
export WS_ID=<resource ID of the CPS Log Analytics workspace that has Sentinel>
EOF
source ~/sbom-deploy.env
```

You also need these landing-zone values for step 9: the VNet ID, three subnet IDs and six private DNS zone IDs (see step 3).

---

## Stage A — Make the copy yours

### Step 1 — Point the code at your org, runner and state storage

**Who:** platform engineer. **Where:** your machine, in a clone of the source repo.

Three things in the code are specific to where this repo was built:

| What | Where | If left unchanged |
|---|---|---|
| Repo path `sg-cloud-platform/cps-security-platform-infra` | Workflow header comments, `sentinel.tf` (workbook ID seed) | Harmless, but misleading |
| Runner label `cps-ubuntu-latest-private` | `cd.yml`, `sbom-collector-ci.yml`, `sbom-scan.yml`, `image-scan.yml`, `container-sbom.yml`, `release-sbom-attest.yml`, `.github/actionlint.yaml` | Jobs queue forever if your org has no runner with that label |
| State backend `rg-tfstate-security-platform` / `stsecplatstate001` | `versions.tf` | `terraform init` fails or writes to someone else's account |

The runner must be **self-hosted with a route into the landing-zone VNet**. GitHub-hosted runners can't reach the private endpoints, so they won't work. Terraform writes a Key Vault secret over the private endpoint, and `sbom-scan.yml` uploads to the internal Dependency-Track.

```bash
source ~/sbom-deploy.env
git switch feature/enterprise-sbom-platform
git switch -c deploy/$ENV

EXCLUDE=':!docs/enterprise-sbom/deployment-runbook.md'
git grep -l 'sg-cloud-platform/cps-security-platform-infra' -- . "$EXCLUDE" \
  | xargs perl -pi -e "s#sg-cloud-platform/cps-security-platform-infra#$GH_REPO#g"
git grep -l 'cps-ubuntu-latest-private' -- . "$EXCLUDE" \
  | xargs perl -pi -e "s#cps-ubuntu-latest-private#$RUNNER#g"
perl -pi -e "s#\"rg-tfstate-security-platform\"#\"$STATE_RG\"#; s#\"stsecplatstate001\"#\"$STATE_SA\"#" versions.tf

git diff --stat
git commit -am "Configure for $GH_REPO"
```

**Check:** `git grep -n -e stsecplatstate001 -e cps-ubuntu-latest-private -- . "$EXCLUDE"` prints nothing.

### Step 2 — Create the repo and push

**Who:** admin of the new repo. **Where:** your machine.

Push with git. **Don't copy the folder or a zip of it.** `poc/secrets/` (real API keys and a GitHub App private key) and `sbom-collector/local.settings.json` are git-ignored, so git leaves them behind. A file copy would take them along.

```bash
gh repo create $GH_REPO --internal --description "CPS enterprise SBOM platform"
git remote add team https://github.com/$GH_REPO.git
git push team deploy/$ENV:main

# Let other repos call sbom-scan.yml and the other reusable workflows.
# Use "enterprise" if repos in other orgs will call them.
gh api -X PUT repos/$GH_REPO/actions/permissions/access -f access_level=organization
```

The push to `main` starts `cd.yml`. That run fails at Azure login because there are no secrets yet. This is expected and changes nothing.

**Check:** `gh api repos/$GH_REPO/contents/poc --jq '.[].name'` lists no `secrets` entry. Protect `main` (Settings → Branches) so changes go through pull requests.

---

## Stage B — Azure prerequisites

### Step 3 — Landing zone

**Who:** landing-zone team; the platform engineer checks. **Where:** anywhere with `az`.

Ask for:

| Item | Requirement |
|---|---|
| Function integration subnet | Delegated to `Microsoft.App/environments` |
| Container Apps infrastructure subnet | /27 or larger, delegated to `Microsoft.App/environments` |
| Private endpoint subnet | No delegation |
| Private DNS zones, linked to (or resolved from) the VNet | `privatelink.vaultcore.azure.net`, `privatelink.blob.core.windows.net`, `privatelink.queue.core.windows.net`, `privatelink.table.core.windows.net`, `privatelink.file.core.windows.net`, `privatelink.postgres.database.azure.com` |
| Runner network | `$RUNNER` resolves the landing zone's private DNS and routes to the private endpoint subnet |
| Corporate DNS forwarding | Requested now. The domain to forward is only known after step 10; see step 11 |

Then check and register the resource providers:

```bash
source ~/sbom-deploy.env
az account set -s $SUB

for s in <function-subnet-id> <container-apps-subnet-id>; do
  az network vnet subnet show --ids "$s" \
    --query "{name:name, prefix:addressPrefix, delegation:delegations[0].serviceName}" -o table
done

for ns in Microsoft.App Microsoft.Web Microsoft.KeyVault Microsoft.Storage Microsoft.DBforPostgreSQL \
          Microsoft.Insights Microsoft.OperationalInsights Microsoft.SecurityInsights; do
  az provider register --namespace $ns
done
```

**Check:** both subnets show `Microsoft.App/environments`. `az provider show -n Microsoft.App --query registrationState -o tsv` prints `Registered`.

### Step 4 — Terraform state storage

**Who:** subscription Owner. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
az group create -n $STATE_RG -l $LOCATION
az storage account create -n $STATE_SA -g $STATE_RG -l $LOCATION \
  --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false
az storage account blob-service-properties update -n $STATE_SA -g $STATE_RG --enable-versioning true
az storage container-rm create --storage-account $STATE_SA -g $STATE_RG -n terraform-state
```

The backend signs in with Entra ID (`use_azuread_auth`), so shared keys can stay off. Versioning lets you recover an earlier state file.

### Step 5 — Deployer identity for GitHub Actions

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

The subject names the **environment**, not the branch. Both `cd.yml` jobs run in the `security-platform` environment, and GitHub then issues `repo:<org>/<repo>:environment:security-platform` as the token subject. A `ref:refs/heads/main` credential would never match. Branch control comes from the environment's reviewers (step 9) and from protecting `main`.

### Step 6 — Resource group and deployer roles

**Who:** subscription Owner. The landing-zone team grants the network roles. **Where:** anywhere with `az`.

```bash
source ~/sbom-deploy.env
# Works in bash and zsh (zsh does not word-split an unquoted $VAR)
grant() { az role assignment create --assignee-object-id $DEPLOYER_SP --assignee-principal-type ServicePrincipal "$@"; }

az group create -n $RG -l $LOCATION
RG_ID=$(az group show -n $RG --query id -o tsv)

grant --role Contributor --scope $RG_ID
# Terraform creates role assignments. This lets it grant only the data-plane roles the platform uses.
grant --role "Role Based Access Control Administrator" --scope $RG_ID \
  --condition-version 2.0 --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {00482a5a-887f-4fb3-b363-3b7fe8e74483, 4633458b-17de-408a-b874-0445c86b69e6, b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3, 3913510d-42f4-4e42-8a64-420c390055eb}))"

# Terraform state
grant --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n $STATE_SA -g $STATE_RG --query id -o tsv)

# CPS workspace's resource group: custom tables, saved function, watchlist, analytics rule, workbook
WS_RG_ID=$(echo $WS_ID | cut -d/ -f1-5)
for role in "Log Analytics Contributor" "Microsoft Sentinel Contributor" "Workbook Contributor"; do
  grant --role "$role" --scope $WS_RG_ID
done

# Landing zone: join the subnets, link the Container Apps private DNS zone to the VNet,
# and register private endpoint records. The landing zone may have a narrower custom role for this.
grant --role "Network Contributor" --scope <vnet-id>
grant --role "Private DNS Zone Contributor" --scope <private-dns-zones-resource-group-id>
```

The conditioned GUIDs are, in order: Key Vault Administrator, Key Vault Secrets User, Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor and Monitoring Metrics Publisher.

**Check:** `az role assignment list --assignee $DEPLOYER_SP --all -o table` shows every assignment above.

---

## Stage C — GitHub App and repo settings

### Step 7 — Create the collector GitHub App

**Who:** GitHub enterprise owner. **Where:** browser.

1. Go to Enterprise → Settings → GitHub Apps → **New GitHub App**.
   - Name `cps-sbom-collector`. Use any homepage URL. Untick **Webhook → Active**.
   - Repository permissions: **Contents** read, **Metadata** read, **Dependabot alerts** read. Nothing else.
   - Installable only on this enterprise.
2. Note the **App ID** and record it:
   ```bash
   echo "export GITHUB_APP_ID=<app id>" >> ~/sbom-deploy.env
   ```
3. **Generate a private key.** The Key Vault doesn't exist until step 10, so keep the `.pem` somewhere safe until step 12, then delete it.
4. Install the App on `$PILOT_ORG` with **All repositories**.

Also create a **read-only GitHub token** for Dependency-Track's GitHub Advisories mirror: a fine-grained token with public-repository read only, ideally owned by a service account. Step 14 uses it.

### Step 8 — Turn on the dependency graph for the pilot org

**Who:** GitHub enterprise owner. **Where:** your machine, in the repo.

```bash
source ~/sbom-deploy.env
gh auth refresh -h github.com -s admin:enterprise
scripts/github/security-config.sh --enterprise $ENTERPRISE --pilot-org $PILOT_ORG
```

This creates `cps-sbom-baseline` (dependency graph, automatic dependency submission and Dependabot alerts on; paid features `not_set`) and attaches it to every repo in the pilot org. If the attach returns 404, apply the configuration to the org in the UI: Enterprise → Settings → Code security → Configurations.

**Check:** in a pilot repo, Insights → Dependency graph shows dependencies.

### Step 9 — Terraform variables, repo secrets and environment

**Who:** admin of the new repo. **Where:** your machine.

Write `terraform.tfvars.json`. It's git-ignored. **Keep a copy outside the repo**: GitHub secrets can't be read back, and you'll edit this file again in steps 19 and 22.

```bash
source ~/sbom-deploy.env
cat > terraform.tfvars.json <<JSON
{
  "environment": "$ENV",
  "global_name_suffix": "$SFX",
  "vnet_id": "<vnet id>",
  "function_subnet_id": "<function subnet id>",
  "container_apps_subnet_id": "<container apps subnet id>",
  "private_endpoint_subnet_id": "<private endpoint subnet id>",
  "private_dns_zone_ids": {
    "vault": "<privatelink.vaultcore.azure.net zone id>",
    "blob": "<privatelink.blob.core.windows.net zone id>",
    "queue": "<privatelink.queue.core.windows.net zone id>",
    "table": "<privatelink.table.core.windows.net zone id>",
    "file": "<privatelink.file.core.windows.net zone id>",
    "postgres": "<privatelink.postgres.database.azure.com zone id>"
  },
  "cps_workspace_id": "$WS_ID",
  "github_enterprise_slug": "$ENTERPRISE",
  "github_app_id": "$GITHUB_APP_ID",
  "alert_email": "<team mailbox for collector alerts>"
}
JSON
jq . terraform.tfvars.json > /dev/null && echo valid
cp terraform.tfvars.json ~/sbom-terraform.tfvars.json
```

[`terraform.tfvars.example`](../../terraform.tfvars.example) explains every variable. Add `"deployer_ip_ranges": ["<runner egress CIDR>"]` only if the runner can't reach the Key Vault private endpoint.

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

---

## Stage D — Deploy

### Step 10 — Plan, then apply

**Who:** platform engineer, plus an environment reviewer. **Where:** your machine (the runner does the work).

```bash
source ~/sbom-deploy.env
gh workflow run cd.yml -R $GH_REPO -f action=plan
sleep 10; RUN=$(gh run list -R $GH_REPO -w cd.yml -L 1 --json databaseId -q '.[0].databaseId')
# A reviewer approves the run: Actions → the run → Review deployments
gh run watch $RUN -R $GH_REPO
gh run view $RUN -R $GH_REPO --log | grep -E 'Plan:|Error'
```

Read the plan. Everything should be created and nothing destroyed. Then apply:

```bash
gh workflow run cd.yml -R $GH_REPO -f action=apply
sleep 10; RUN=$(gh run list -R $GH_REPO -w cd.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run watch $RUN -R $GH_REPO
```

The run asks for approval twice: once for `terraform`, once for `collector-deploy`. Postgres and the Container Apps environment are the slow parts, so allow 30–60 minutes.

If the plan fails because a name is taken (the Key Vault, storage accounts and Postgres server need globally unique names):
1. Set `SFX` in `~/sbom-deploy.env`.
2. Add `"global_name_suffix"` to the tfvars and update `TF_VARS_JSON`.
3. Re-set `FUNCTION_APP_NAME`.
4. Run the plan again.

### Step 11 — Check the deployment and get the addresses

**Who:** platform engineer, then the landing-zone team. **Where:** anywhere with `az`; the `curl` needs the admin workstation.

```bash
source ~/sbom-deploy.env
az resource list -g $RG --query "[].{name:name, type:type}" -o table

CAE_DOMAIN=$(az containerapp env show -g $RG -n cae-sbom-$ENV --query properties.defaultDomain -o tsv)
CAE_IP=$(az containerapp env show -g $RG -n cae-sbom-$ENV --query properties.staticIp -o tsv)
cat >> ~/sbom-deploy.env <<EOF
export CAE_DOMAIN=$CAE_DOMAIN CAE_IP=$CAE_IP
export DT_UI=https://ca-dtrack-ui.$CAE_DOMAIN DT_API=https://ca-dtrack-api.$CAE_DOMAIN
EOF
source ~/sbom-deploy.env
echo "Forward $CAE_DOMAIN -> $CAE_IP"

az functionapp show -g $RG -n $FUNC --query "{state:state, host:defaultHostName}" -o table
```

**Ask the landing-zone team** to make `$CAE_DOMAIN` resolve to `$CAE_IP` from the corporate network (a conditional forwarder or a wildcard record), so teams can reach Dependency-Track. Until that's done:
- use a jump box in the VNet (the environment's private DNS zone is linked there); or
- on a VPN machine, add one hosts-file line: `<CAE_IP> ca-dtrack-ui.<CAE_DOMAIN> ca-dtrack-api.<CAE_DOMAIN>`.

The browser needs **both** names, because the UI calls the API directly.

**Check (admin workstation):** `curl -s $DT_API/api/version` returns JSON with `"version":"4.14.6"`. The first start creates the database schema and can take several minutes. The vulnerability mirrors then fill over the next few hours.

---

## Stage E — Secrets and Dependency-Track

### Step 12 — Key Vault access and the App private key

**Who:** subscription Owner grants the role; platform engineer stores the key. **Where:** admin workstation (the vault only accepts its private endpoint).

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

### Step 13 — First Dependency-Track login

**Who:** platform engineer. **Where:** admin workstation, browser.

1. Open `$DT_UI` and sign in as `admin` / `admin`. You're forced to change the password.
2. Keep the new password in Key Vault, for recovery until Entra sign-in works:
   ```bash
   read -rs P && az keyvault secret set --vault-name $KV -n dtrack-admin-password --value "$P" --output none; unset P
   ```
3. Go to Administration → Access Management → Teams → **Administrators** → API Keys → **+**. Copy the key; it's temporary and step 20 deletes it.

### Step 14 — Bootstrap Dependency-Track and onboard the pilot org

**Who:** platform engineer. **Where:** admin workstation, in the repo, signed in with `az login` (the script writes the API keys to Key Vault as you).

```bash
source ~/sbom-deploy.env
cd sbom-collector
python3.11 -m venv .venv && .venv/bin/pip install -q -r requirements.txt

export DTRACK_URL=$DT_API
read -rs DTRACK_ADMIN_API_KEY && export DTRACK_ADMIN_API_KEY          # paste the key from step 13
read -rs GITHUB_ADVISORIES_TOKEN && export GITHUB_ADVISORIES_TOKEN    # the read-only token from step 7

.venv/bin/python ops/dtrack_admin.py bootstrap --key-vault-url https://$KV.vault.azure.net/
.venv/bin/python ops/dtrack_admin.py onboard-org $PILOT_ORG          # add --teams-webhook <url> for Teams notifications
```

`bootstrap` does the following:
- Turns on portfolio access control and the NVD, OSV and GitHub Advisories sources.
- Creates the teams `bom-uploader`, `ci-uploader`, `acl-sync` and `sg-sbom-cps-admins`.
- Writes their keys to Key Vault as `dtrack-api-key`, `dtrack-ci-api-key` and `dtrack-acl-key`.
- Adds the `CPS restricted` licence group and the three starter policies.

`onboard-org` creates the pilot org's parent project, its team `sg-sbom-org-<org>` and the team's access. Both commands are safe to re-run.

**Check:**
- `az keyvault secret list --vault-name $KV --query "[].name" -o tsv` now also lists the three `dtrack-*` keys.
- In the UI, Administration → Teams shows the five teams.
- Policy Management shows three policies.
- Projects shows `$PILOT_ORG`.

### Step 15 — Restart the collector

**Who:** platform engineer. **Where:** anywhere with `az`.

The collector caches secrets for the life of an instance, so restart it to pick up the new keys:

```bash
az functionapp restart -g $RG -n $FUNC
```

---

## Stage F — First collection (pilot)

### Step 16 — Run the first collection

**Who:** platform engineer. **Where:** anywhere with `az`. The Function App's admin endpoint is public and authenticated with its master key.

```bash
source ~/sbom-deploy.env
FUNC_HOST=$(az functionapp show -g $RG -n $FUNC --query defaultHostName -o tsv)
MASTER=$(az functionapp keys list -g $RG -n $FUNC --query masterKey -o tsv)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://$FUNC_HOST/admin/functions/enumerate_repos" \
  -H "x-functions-key: $MASTER" -H 'Content-Type: application/json' -d '{}'
```

Expect `202`. Rows reach Sentinel a few minutes later. Run these in the CPS workspace → Logs:

```kusto
GitHubSbomRun_CL
| where TimeGenerated > ago(3h)
| summarize Repos = dcount(Repo) by Org, Status
```

```kusto
FunctionAppLogs
| where TimeGenerated > ago(3h) and Level in ("Warning", "Error")
| project TimeGenerated, FunctionName, Level, Message
```

GitHub allows **100 SBOMs an hour per org**, so an org of more than 100 repos takes hours to collect. Throttled jobs wait on the queue; that's expected. The statuses are explained in [how-to-use §4](../how-to-use.md#4-sentinel-for-cps).

**Check:**
- The pilot org's repos show `ok` (or `no-dependency-graph` for repos with no manifests).
- In Dependency-Track, `$PILOT_ORG` has `$PILOT_ORG/<repo>` children.
- For three repos, compare the component counts with GitHub → Insights → Dependency graph.

### Step 17 — Test the Terraform path (`sbom-scan.yml`)

**Who:** admin of the new repo. **Where:** admin workstation (reads Key Vault).

```bash
source ~/sbom-deploy.env
gh variable set DEPENDENCY_TRACK_URL -R $GH_REPO --body $DT_API
az keyvault secret show --vault-name $KV -n dtrack-ci-api-key --query value -o tsv \
  | gh secret set DEPENDENCY_TRACK_API_KEY -R $GH_REPO
gh workflow run test-sbom-scan.yml -R $GH_REPO
```

**Check:** project `<owner>/<repo>/terraform` appears under the parent `<owner>`, where `<owner>` is the org that owns `$GH_REPO`. If that org isn't onboarded, the parent is still created, but only CPS admins see it until you run `onboard-org` for it.

To let every Terraform repo in an org use the scan, set both values once at org level:

```bash
gh variable set DEPENDENCY_TRACK_URL --org <org> --visibility all --body $DT_API
```

Do the same for the secret with `gh secret set DEPENDENCY_TRACK_API_KEY --org <org> --visibility all`.

### Step 18 — Pilot gate

**Who:** platform engineer. **Where:** Sentinel and the alert mailbox.

Collection now runs by itself every night:
- `enumerate_repos` at 02:00 UTC.
- `sync_dtrack_acl` at 04:30 UTC.
- `report_poison_depth` every 15 minutes.

Wait for **five consecutive nights** with:
- no `sbom-poison-queue-not-empty` alert;
- no `sbom-enumerate-not-succeeded` alert;
- coverage that holds steady in [`coverage-by-org.kql`](../../sbom-collector/kql/coverage-by-org.kql).

Record the result in the [delivery plan](delivery-plan.md) under Phase 1.

---

## Stage G — Entra sign-in

### Step 19 — Groups and the Dependency-Track app registration

**Who:** Entra admin. **Where:** anywhere with `az`.

There are two options:

- **Option B, by hand (recommended).** You create the groups and the app with the commands below.
- **Option A, Terraform (`manage_entra = true`).** Terraform creates them, but the CI identity then needs `AppRoleAssignment.ReadWrite.All`, which lets it grant itself any permission in the tenant. Most government tenants won't allow that on a pipeline identity.

**Option B — by hand**

```bash
source ~/sbom-deploy.env
for g in sg-sbom-cps-admins sg-sbom-org-$PILOT_ORG; do az ad group create --display-name $g --mail-nickname $g --output none; done

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
for g in sg-sbom-cps-admins sg-sbom-org-$PILOT_ORG; do
  GID=$(az ad group show --group $g --query id -o tsv)
  az rest --method POST --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP/appRoleAssignedTo \
    --headers Content-Type=application/json \
    --body "{\"principalId\": \"$GID\", \"resourceId\": \"$DT_SP\", \"appRoleId\": \"00000000-0000-0000-0000-000000000000\"}" \
    --output none
done

echo "export DT_APP=$DT_APP DT_SP=$DT_SP" >> ~/sbom-deploy.env
```

Then add `"dtrack_oidc_client_id": "<DT_APP>"` to `~/sbom-terraform.tfvars.json`. Update `TF_VARS_JSON` from it and apply, as in step 10:

```bash
gh secret set TF_VARS_JSON -R $GH_REPO < ~/sbom-terraform.tfvars.json
gh workflow run cd.yml -R $GH_REPO -f action=apply
```

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

Then add `"manage_entra": true` and `"sbom_orgs": ["<pilot org>"]` to the tfvars, update `TF_VARS_JSON` and apply.

**Both options:** add the people:

```bash
az ad group member add --group sg-sbom-cps-admins --member-id $(az ad user show --id <upn> --query id -o tsv)
```

Repeat for each CPS admin, and for the pilot team's nominated members in `sg-sbom-org-$PILOT_ORG`.

### Step 20 — Switch to Entra sign-in

**Who:** a member of `sg-sbom-cps-admins`. **Where:** admin workstation, browser.

1. Open `$DT_UI` and sign in with **OpenID**. You should see Administration and every project.
2. Ask a pilot-team member to sign in. They should see only `$PILOT_ORG` and its repos.
3. Suspend the local admin: Administration → Access Management → Managed Users → `admin` → **Suspended**.
4. Delete the temporary API key from step 13: Teams → Administrators → API Keys.

---

## Stage H — Every org

### Step 21 — `cps-sbom-baseline` across the enterprise

**Who:** GitHub enterprise owner. **Where:** your machine, in the repo.

```bash
scripts/github/security-config.sh --enterprise $ENTERPRISE --enterprise-wide
```

The script first lists the existing configurations. Repos already on another configuration keep it. Add the three settings (dependency graph, automatic dependency submission, Dependabot alerts) to those configurations, or re-run with `--include-configured` to replace them.

### Step 22 — Install the collector on every org automatically

**Who:** GitHub enterprise owner, then platform engineer. **Where:** browser, then admin workstation.

1. Go to Enterprise → Settings → GitHub Apps → **New GitHub App** `cps-app-installer`, with webhook off. Give it the enterprise permission **Enterprise organization installations**, read and write. Install it on the **enterprise**, not on orgs.
2. Note the App ID. Then get the installation ID, the number at the end of the installation's settings URL.
3. Generate a private key, then store it:
   ```bash
   az keyvault secret set --vault-name $KV -n github-installer-private-key --file <installer>.private-key.pem --output none
   ```
4. Add the two IDs to the tfvars, then update `TF_VARS_JSON` and apply:
   ```json
   "github_installer_app_id": "<app id>",
   "github_installer_installation_id": "<installation id>"
   ```
5. Run the installer once rather than waiting for Monday 03:00 UTC (`FUNC_HOST` and `MASTER` as in step 16):
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://$FUNC_HOST/admin/functions/install_collector_on_new_orgs" \
     -H "x-functions-key: $MASTER" -H 'Content-Type: application/json' -d '{}'
   ```

**Check:** `FunctionAppLogs | where Message has "collector on"` shows a line for each org it installed on, or switched to all repositories.

### Step 23 — Onboard each org

**Who:** Entra admin and platform engineer. **Where:** admin workstation. Allow about 30 minutes per org; [how-to-use §5](../how-to-use.md#5-onboarding-an-org) has the detail.

```bash
ORG=<github org login, exactly as GitHub spells it>
# Option B: create the group and assign it to the Dependency-Track app
az ad group create --display-name sg-sbom-org-$ORG --mail-nickname sg-sbom-org-$ORG --output none
GID=$(az ad group show --group sg-sbom-org-$ORG --query id -o tsv)
az rest --method POST --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP/appRoleAssignedTo \
  --headers Content-Type=application/json \
  --body "{\"principalId\": \"$GID\", \"resourceId\": \"$DT_SP\", \"appRoleId\": \"00000000-0000-0000-0000-000000000000\"}"
# (Option A: add the org to sbom_orgs and apply instead.)

az ad group member add --group sg-sbom-org-$ORG --member-id <member object id>   # for each nominated member

cd sbom-collector
export DTRACK_URL=$DT_API
read -rs DTRACK_ADMIN_API_KEY && export DTRACK_ADMIN_API_KEY   # a CPS admin key (Teams → sg-sbom-cps-admins → API Keys)
.venv/bin/python ops/dtrack_admin.py onboard-org $ORG --teams-webhook <team channel webhook URL>
```

Delete the admin API key when you're done.

### Step 24 — Sentinel content and the rollout gate

**Who:** CPS security and platform engineer. **Where:** Sentinel.

1. Agree the first banned packages with CPS security. Add them as `banned_packages` in the tfvars (`[{"PackageName": "...", "Reason": "..."}]`), then update `TF_VARS_JSON` and apply.
2. Check Sentinel → Workbooks → **SBOM coverage and inventory**, and that the analytics rule *SBOM: banned package in use* is enabled.
3. **Gate:** at least 95% of active repos have a fresh SBOM (the workbook's coverage tile), and each org team signs in and sees only its own org.

---

## After go-live

- **Changing the platform:** open a pull request, merge it to `main`, and `cd.yml` runs plan and apply after a reviewer approves. Collector code changes deploy in the same run. Keep `~/sbom-terraform.tfvars.json` as the source for `TF_VARS_JSON`.
- **Day to day:** [how-to-use](../how-to-use.md) covers the operating model, rotating credentials (§9) and the failure runbook (§10).
- **Phase 3 (optional):** container image SBOMs and attested release SBOMs; see [how-to-use §7](../how-to-use.md#7-container-images-and-bicep-repos) and the [delivery plan](delivery-plan.md#phase-3--depth-jan--mar-2027).
- **The old stack:** only applies if the earlier DefectDojo platform (`rg-security-platform`) was ever deployed in your tenant. Its decommissioning is in the delivery plan, Phase 2.

## Troubleshooting the first deployment

| Symptom | Cause | Fix |
|---|---|---|
| `cd.yml` jobs stay *Queued* | No runner with the `$RUNNER` label | Check the label from step 1 matches a runner registered to the repo or org |
| `AADSTS700213` / `AADSTS70021` at Azure login | The federated credential subject doesn't match | It must be `repo:<org>/<repo>:environment:security-platform`, matching `$GH_REPO` exactly (step 5) |
| `AuthorizationFailed` creating a role assignment | RBAC Administrator role or its condition missing | Re-run step 6 |
| Plan fails: the storage account, Key Vault or Postgres name is taken | Globally unique names | Set `global_name_suffix` (step 10) |
| Apply hangs or fails writing `postgres-admin-password` | The runner can't reach the Key Vault private endpoint | Fix the runner's DNS and route (step 3), or set `deployer_ip_ranges` |
| `collector-deploy` can't find the app | `FUNCTION_APP_NAME` doesn't match | `gh variable set FUNCTION_APP_NAME --body $FUNC` |
| `ForbiddenByConnection` from `az keyvault` | Not on the admin workstation | Run from inside the network (step 12) |
| `Forbidden` from `az keyvault secret set` | No Secrets Officer role yet, or it hasn't applied | Step 12; wait a few minutes after granting |
| Dependency-Track UI loads but sign-in or every page fails | The browser can't resolve `ca-dtrack-api.<domain>` | DNS forwarding or hosts file must cover both names (step 11) |
| Dependency-Track returns 500 after a while | Look at the API server log | `az containerapp logs show -g $RG -n ca-dtrack-api --tail 100` |
| `enumerate_repos` logs a 401 | Wrong or missing `github-app-private-key` | Re-store the key (step 12), then restart (step 15) |
| Every repo in the pilot org is `no-dependency-graph` | `cps-sbom-baseline` not applied yet, or the App was installed on selected repositories | Step 8; set the installation to All repositories |
