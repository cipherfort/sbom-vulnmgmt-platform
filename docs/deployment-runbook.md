# Deployment runbook

This takes you from an empty subscription to nightly collection, deploying through GitHub Actions. Running it from your own machine is covered in [Deploying without the pipeline](#deploying-without-the-pipeline). If something goes wrong, see [Troubleshooting](how-to-use.md#troubleshooting).

## What you need

- **Azure:** Owner on the subscription, to create the resource group and grant roles.
- **GitHub:** an owner of the org, and admin rights on this repo.
- **Tools:** `az`, `gh` and `jq`. Deploying by hand also needs Terraform 1.11 or later, Python 3.11, `rsync` and `zip`.

Save these values in a file outside the repo, and run `source ~/sbom.env` in each new terminal:

```bash
cat > ~/sbom.env <<'EOF'
export SUB=<subscription id>
export TENANT=<Entra tenant id>
export ENV=prd                       # names become rg-sbom-prd, kv-sbom-prd, ...
export RG=rg-sbom-$ENV
export KV=kv-sbom-$ENV              # add your global_name_suffix here if you set one
export STATE_RG=<state storage resource group>
export STATE_SA=<state storage account>
export GH_REPO=<org>/<this repo>
export ORG=<GitHub org to collect>
EOF
source ~/sbom.env
```

## 1. Point the repo at your environment

Terraform state goes to the storage account named in [`versions.tf`](../versions.tf). Change it to yours:

```bash
perl -pi -e "s#\"rg-tfstate-security-platform\"#\"$STATE_RG\"#; s#\"stsecplatstate001\"#\"$STATE_SA\"#" versions.tf
```

The workflows run on the runner label `cps-ubuntu-latest-private`. If your org doesn't have that runner, switch to GitHub's own runners. Then delete `.github/actionlint.yaml`, which only exists to declare that label:

```bash
git grep -l cps-ubuntu-latest-private -- .github | xargs perl -pi -e 's/cps-ubuntu-latest-private/ubuntu-latest/g'
git rm .github/actionlint.yaml
```

Commit and push to `main`.

## 2. Azure: state, resource group and deployer

```bash
source ~/sbom.env
az account set -s $SUB
for ns in Microsoft.App Microsoft.Web Microsoft.KeyVault Microsoft.Storage Microsoft.DBforPostgreSQL \
          Microsoft.Insights Microsoft.OperationalInsights; do az provider register -n $ns; done

# State storage (skip if you already have an account)
az group create -n $STATE_RG -l uksouth
az storage account create -n $STATE_SA -g $STATE_RG -l uksouth --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false
az storage container-rm create --storage-account $STATE_SA -g $STATE_RG -n terraform-state

# The platform's resource group (uksouth or ukwest)
az group create -n $RG -l uksouth
```

Create the identity GitHub Actions deploys as. It trusts the `main` branch only, so runs from any other branch can't sign in to Azure:

```bash
APP=$(az ad app create --display-name sp-sbom-platform-github-actions --query appId -o tsv)
SP=$(az ad sp create --id $APP --query id -o tsv)
az ad app federated-credential create --id $APP --parameters "{
  \"name\": \"main\", \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"repo:$GH_REPO:ref:refs/heads/main\", \"audiences\": [\"api://AzureADTokenExchange\"]}"
echo "export APP=$APP SP=$SP" >> ~/sbom.env
```

Give it its roles. It needs Contributor, plus permission to grant the six roles the platform uses:

```bash
RG_ID=$(az group show -n $RG --query id -o tsv)
grant() { az role assignment create --assignee-object-id $SP --assignee-principal-type ServicePrincipal "$@"; }
grant --role Contributor --scope $RG_ID
grant --role "Role Based Access Control Administrator" --scope $RG_ID --condition-version 2.0 \
  --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {00482a5a-887f-4fb3-b363-3b7fe8e74483, 4633458b-17de-408a-b874-0445c86b69e6, b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3, 3913510d-42f4-4e42-8a64-420c390055eb}))"
grant --role "Storage Blob Data Contributor" --scope $(az storage account show -n $STATE_SA -g $STATE_RG --query id -o tsv)
```

The six roles are Key Vault Administrator, Key Vault Secrets User, Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor and Monitoring Metrics Publisher.

## 3. GitHub: App, dependency graph and secrets

**Create the collector App** (in the browser): Org → Settings → Developer settings → GitHub Apps → New GitHub App.
- Any name, for example `cps-sbom-collector`. Turn off the webhook.
- Repository permissions: **Contents: read** and **Metadata: read**. Nothing else.
- Installable on **this account only**.

Then note the **App ID**, generate a **private key**, and install the App on the org with **All repositories**.

**Turn on the dependency graph** for every repo:

```bash
gh auth refresh -h github.com -s admin:org
scripts/github/security-config.sh --org $ORG
```

**Add the repo secrets** and protect `main`. Every merge to `main` deploys, so changes must go through a reviewed pull request. [`terraform.tfvars.example`](../terraform.tfvars.example) explains each variable.

```bash
cat > ~/sbom.tfvars.json <<JSON
{
  "environment": "$ENV",
  "github_app_id": "<App ID>",
  "alert_email": "<team mailbox>",
  "allowed_ip_ranges": ["<office or VPN egress IP>/32"]
}
JSON
gh secret set TF_VARS_JSON              -R $GH_REPO < ~/sbom.tfvars.json
gh secret set AZURE_CLIENT_ID           -R $GH_REPO --body $APP
gh secret set AZURE_TENANT_ID           -R $GH_REPO --body $TENANT
gh secret set AZURE_SUBSCRIPTION_ID     -R $GH_REPO --body $SUB
gh secret set COLLECTOR_APP_PRIVATE_KEY -R $GH_REPO < <downloaded>.private-key.pem
rm <downloaded>.private-key.pem

gh api -X PUT repos/$GH_REPO/branches/main/protection --input - <<'JSON'
{"required_status_checks": null, "enforce_admins": true,
 "required_pull_request_reviews": {"required_approving_review_count": 1}, "restrictions": null}
JSON
```

Two more settings are optional:
- **`DT_ADVISORIES_TOKEN` secret:** a read-only GitHub token. It turns on the GitHub Advisories vulnerability source.
- **`SBOM_ORG` variable:** set it if the org to collect isn't the org this repo is in.

## 4. Deploy

```bash
gh workflow run cd.yml -R $GH_REPO --ref main -f action=apply
sleep 10; gh run watch -R $GH_REPO $(gh run list -R $GH_REPO -w cd.yml -L 1 --json databaseId -q '.[0].databaseId')
```

This creates the platform, which is 38 resources and takes 20–40 minutes, and then deploys the collector code. The run fails if the Function doesn't load its three functions.

Then run the one-off setup:

```bash
gh workflow run sbom-setup.yml -R $GH_REPO --ref main
sleep 10; gh run watch -R $GH_REPO $(gh run list -R $GH_REPO -w sbom-setup.yml -L 1 --json databaseId -q '.[0].databaseId')
```

This run:
1. Stores the App key in Key Vault.
2. Sets the Dependency-Track admin password and stores it in Key Vault.
3. Creates the teams, API keys, policies and vulnerability sources.
4. Restarts both apps.
5. Starts the first collection.

**Check**, after about 10 minutes:

```bash
az monitor app-insights query -g $RG --app appi-sbom-$ENV \
  --analytics-query "$(cat sbom-collector/kql/collector-status.kql)" -o table
```

Repos should show `ok`. GitHub allows 100 SBOMs an hour, so an org with more repos takes several hours to collect the first time. Vulnerability counts appear the next day, once Dependency-Track has downloaded its vulnerability databases.

## 5. Give people access

Reading the admin password needs a Key Vault role. Grant it to a group rather than to individuals:

```bash
az role assignment create --assignee-object-id <admins group object id> --assignee-principal-type Group \
  --role "Key Vault Secrets Officer" --scope $(az keyvault show -n $KV --query id -o tsv)
az keyvault secret show --vault-name $KV -n dtrack-admin-password --query value -o tsv
```

Sign in to the UI as `admin`. Its address is in the summary of the setup run. In Administration → Access Management → Managed Users, create an account for each person. Add each account to the team `sg-sbom-cps-admins` (full admin) or `sg-sbom-cps-users` (view and triage).

To use Entra accounts instead, see the next section.

## Optional: Entra sign-in

People then sign in with their work account, and two Entra groups control access. The group names must be exactly these, because the Dependency-Track teams are mapped to them.

```bash
source ~/sbom.env
for g in sg-sbom-cps-admins sg-sbom-cps-users; do az ad group create --display-name $g --mail-nickname $g -o none; done

DT_UI=$(az containerapp show -g $RG -n ca-dtrack-ui --query properties.configuration.ingress.fqdn -o tsv)
DT_APP=$(az ad app create --display-name "Dependency-Track ($ENV)" --sign-in-audience AzureADMyOrg --query appId -o tsv)
az rest --method PATCH --uri https://graph.microsoft.com/v1.0/applications/$(az ad app show --id $DT_APP --query id -o tsv) \
  --headers Content-Type=application/json --body "{
  \"spa\": {\"redirectUris\": [\"https://$DT_UI/static/oidc-callback.html\"]},
  \"groupMembershipClaims\": \"ApplicationGroup\",
  \"optionalClaims\": {
    \"idToken\":     [{\"name\": \"groups\", \"additionalProperties\": [\"cloud_displayname\"]}],
    \"accessToken\": [{\"name\": \"groups\", \"additionalProperties\": [\"cloud_displayname\"]}]}}"

# Only the two groups can sign in
DT_SP=$(az ad sp create --id $DT_APP --query id -o tsv)
az rest --method PATCH --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP \
  --headers Content-Type=application/json --body '{"appRoleAssignmentRequired": true}'
for g in sg-sbom-cps-admins sg-sbom-cps-users; do
  az rest --method POST --uri https://graph.microsoft.com/v1.0/servicePrincipals/$DT_SP/appRoleAssignedTo \
    --headers Content-Type=application/json -o none --body "{\"principalId\": \"$(az ad group show -g $g --query id -o tsv)\",
    \"resourceId\": \"$DT_SP\", \"appRoleId\": \"00000000-0000-0000-0000-000000000000\"}"
done
```

1. Add `"dtrack_oidc_client_id": "<DT_APP>"` to `~/sbom.tfvars.json`.
2. Update the `TF_VARS_JSON` secret from it, and run `cd.yml` with `apply` again.
3. Add people to the two groups.
4. Once Entra sign-in works, suspend the local `admin` account: Managed Users → `admin` → Suspended.

Terraform can create the groups and app itself (`"manage_entra": true`), but the deployer then needs Microsoft Graph application permissions. Most tenants won't allow that on a pipeline identity.

## Optional: Terraform repos

The collector can't see Terraform providers. Terraform repos call [`sbom-scan.yml`](../.github/workflows/sbom-scan.yml); copy the two files in [`examples/consumer-workflows/`](../examples/consumer-workflows/). Set the address and key once for the whole org:

```bash
gh variable set DEPENDENCY_TRACK_URL --org $ORG --visibility all \
  --body "https://$(az containerapp show -g $RG -n ca-dtrack-api --query properties.configuration.ingress.fqdn -o tsv)"
az keyvault secret show --vault-name $KV -n dtrack-ci-api-key --query value -o tsv \
  | gh secret set DEPENDENCY_TRACK_API_KEY --org $ORG --visibility all
gh api -X PUT repos/$GH_REPO/actions/permissions/access -f access_level=organization
```

## Deploying without the pipeline

You can run the same steps from your own machine. You need Owner on the resource group and Storage Blob Data Contributor on the state account. Skip the deployer identity and the GitHub secrets, but keep `~/sbom.tfvars.json`.

```bash
source ~/sbom.env && az login && az account set -s $SUB
export ARM_SUBSCRIPTION_ID=$SUB
terraform init && terraform apply -var-file=$HOME/sbom.tfvars.json

# Collector code. The --platform flags matter: other wheels upload fine but don't load.
FUNC=$(terraform output -raw function_app_name); PKG=$(mktemp -d)
rsync -a --exclude-from=sbom-collector/.funcignore --exclude=.funcignore --exclude=.python_packages sbom-collector/ $PKG/
python3 -m pip install -q --target $PKG/.python_packages/lib/site-packages -r sbom-collector/requirements.txt \
  --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --python-version 3.11 \
  --implementation cp --only-binary=:all:
(cd $PKG && zip -qr ../collector.zip .)
az functionapp deployment source config-zip -g $RG -n $FUNC --src $PKG/../collector.zip
az functionapp function list -g $RG -n $FUNC --query "[].name" -o tsv     # expect three functions

# The same work as sbom-setup.yml
az keyvault secret set --vault-name $KV -n github-app-private-key --file <downloaded>.private-key.pem -o none
python3.11 -m venv .venv && .venv/bin/pip install -q -r sbom-collector/requirements.txt
DTRACK_URL=$(terraform output -raw dependency_track_api_url) KV_URL=https://$KV.vault.azure.net/ ORG=$ORG \
  .venv/bin/python sbom-collector/ops/first_setup.py
az functionapp restart -g $RG -n $FUNC
az containerapp revision restart -g $RG -n ca-dtrack-api \
  --revision $(az containerapp revision list -g $RG -n ca-dtrack-api --query "[?properties.active].name | [0]" -o tsv)
curl -X POST "https://$(az functionapp show -g $RG -n $FUNC --query properties.defaultHostName -o tsv)/admin/functions/enumerate_repos" \
  -H "x-functions-key: $(az functionapp keys list -g $RG -n $FUNC --query masterKey -o tsv)" \
  -H 'Content-Type: application/json' -d '{}'
```

Applying by hand makes you Key Vault Administrator. If the pipeline applies later, that role moves to the pipeline identity.

## Tearing it down

```bash
terraform destroy -var-file=$HOME/sbom.tfvars.json
az monitor action-group delete -g $RG -n "Application Insights Smart Detection"   # created by Azure, not Terraform
az group delete -n $RG --yes
```

The Key Vault is kept soft-deleted for 90 days. A new deployment with the same name in that time recovers it, including its old secrets. That's harmless: `first_setup.py` replaces the old admin password, and Terraform resets the vault's firewall. If an apply fails at `ca-dtrack-api` with `unable to fetch secret`, delete that app (`az containerapp delete -g $RG -n ca-dtrack-api --yes`) and apply again.

Outside Azure, remove these if the platform is going for good:
- the GitHub App;
- the `cps-sbom-baseline` configuration (Org → Settings → Code security);
- the org's `DEPENDENCY_TRACK_*` variable and secret;
- the deployer app and any Entra groups and app registration.
