#!/usr/bin/env bash
# Automates the manual "Bootstrap" steps from the root README: Terraform
# state storage, the OIDC App Registration + federated credential(s), the
# workload resource group, and the two RBAC role assignments. Safe to
# re-run — every step checks whether its resource already exists first.
#
# Does NOT automate: choosing allowed_ip_ranges (your call), creating the
# GitHub Environment/required reviewers, or setting GitHub repo secrets
# (this prints the values instead — set them yourself, or see the
# --set-github-secrets flag if you have `gh` authenticated).
#
# Usage:
#   scripts/bootstrap.sh --github-owner <owner> --github-repo <repo> --name-prefix <prefix> [options]
#
# Required:
#   --github-owner <owner>       GitHub org/user that owns the repo (or fork)
#   --github-repo <repo>         Repo name
#   --name-prefix <prefix>       Matches the name_prefix Terraform variable — 2-12 chars,
#                                 lowercase letters/digits/hyphens, must match what you'll
#                                 set in terraform.tfvars
#
# Optional (defaults shown):
#   --location <region>          uksouth
#   --tfstate-rg <name>          rg-tfstate-security-platform
#   --tfstate-account <name>     stsecplatstate001 (must be globally unique — change if taken)
#   --tfstate-container <name>   terraform-state
#   --app-name <name>            sp-<name_prefix>-github-actions
#   --subscription-id <id>       current `az account show` subscription
#   --set-github-secrets         also set AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_SUBSCRIPTION_ID
#                                 via `gh secret set` (requires `gh` authenticated) — opt-in,
#                                 since this is a bigger blast radius than the Azure-side steps

set -euo pipefail

LOCATION="uksouth"
TFSTATE_RG="rg-tfstate-security-platform"
TFSTATE_ACCOUNT="stsecplatstate001"
TFSTATE_CONTAINER="terraform-state"
SET_GITHUB_SECRETS=false
GITHUB_OWNER=""
GITHUB_REPO=""
NAME_PREFIX=""
APP_NAME=""
SUBSCRIPTION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-owner) GITHUB_OWNER="$2"; shift 2 ;;
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --tfstate-rg) TFSTATE_RG="$2"; shift 2 ;;
    --tfstate-account) TFSTATE_ACCOUNT="$2"; shift 2 ;;
    --tfstate-container) TFSTATE_CONTAINER="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --set-github-secrets) SET_GITHUB_SECRETS=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$GITHUB_OWNER" || -z "$GITHUB_REPO" || -z "$NAME_PREFIX" ]]; then
  echo "Error: --github-owner, --github-repo, and --name-prefix are required." >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

if ! [[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9-]{0,10}[a-z0-9]$ ]]; then
  echo "Error: --name-prefix must be 2-12 characters, lowercase letters/digits/hyphens, start with a letter, end with a letter or digit (matches the Terraform variable's own validation)." >&2
  exit 1
fi

APP_NAME="${APP_NAME:-sp-${NAME_PREFIX}-github-actions}"
WORKLOAD_RG="rg-${NAME_PREFIX}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi

echo "== Subscription: $SUBSCRIPTION_ID =="
echo "== Workload resource group: $WORKLOAD_RG =="
echo "== App Registration: $APP_NAME =="
echo

echo "-- Step 1: Terraform state storage --"
if az group show --name "$TFSTATE_RG" &>/dev/null; then
  echo "Resource group $TFSTATE_RG already exists, skipping create."
else
  az group create --name "$TFSTATE_RG" --location "$LOCATION" -o none
  echo "Created resource group $TFSTATE_RG."
fi

if az storage account show --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" &>/dev/null; then
  echo "Storage account $TFSTATE_ACCOUNT already exists, skipping create."
else
  az storage account create \
    --name "$TFSTATE_ACCOUNT" \
    --resource-group "$TFSTATE_RG" \
    --location "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --allow-blob-public-access false --https-only true -o none
  echo "Created storage account $TFSTATE_ACCOUNT."
fi

if az storage container show --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_ACCOUNT" --auth-mode login &>/dev/null; then
  echo "Storage container $TFSTATE_CONTAINER already exists, skipping create."
else
  az storage container create \
    --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_ACCOUNT" --auth-mode login -o none
  echo "Created storage container $TFSTATE_CONTAINER."
fi

echo
echo "-- Step 2: App Registration + OIDC federated credential --"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [[ -z "$APP_ID" ]]; then
  az ad app create --display-name "$APP_NAME" -o none
  APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
  echo "Created App Registration $APP_NAME ($APP_ID)."
else
  echo "App Registration $APP_NAME already exists ($APP_ID), skipping create."
fi

if az ad sp show --id "$APP_ID" &>/dev/null; then
  echo "Service principal already exists, skipping create."
else
  az ad sp create --id "$APP_ID" -o none
  echo "Created service principal."
fi

CRED_NAME="${NAME_PREFIX}-cd-main"
if az ad app federated-credential list --id "$APP_ID" --query "[?name=='$CRED_NAME']" -o tsv | grep -q .; then
  echo "Federated credential $CRED_NAME already exists, skipping create."
else
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$CRED_NAME\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
  echo "Created federated credential $CRED_NAME for repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main."
fi

echo
echo "-- Step 3: RBAC --"
if az group show --name "$WORKLOAD_RG" &>/dev/null; then
  echo "Resource group $WORKLOAD_RG already exists, skipping create."
else
  az group create --name "$WORKLOAD_RG" --location "$LOCATION" -o none
  echo "Created resource group $WORKLOAD_RG."
fi

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

if az role assignment list --assignee "$SP_OBJECT_ID" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${WORKLOAD_RG}" --role "Contributor" -o tsv | grep -q .; then
  echo "Contributor role assignment on $WORKLOAD_RG already exists, skipping."
else
  az role assignment create --assignee "$SP_OBJECT_ID" --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${WORKLOAD_RG}" -o none
  echo "Granted Contributor on $WORKLOAD_RG."
fi

if az role assignment list --assignee "$SP_OBJECT_ID" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TFSTATE_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_ACCOUNT}" --role "Storage Blob Data Contributor" -o tsv | grep -q .; then
  echo "Storage Blob Data Contributor role assignment already exists, skipping."
else
  az role assignment create --assignee "$SP_OBJECT_ID" --role "Storage Blob Data Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${TFSTATE_RG}/providers/Microsoft.Storage/storageAccounts/${TFSTATE_ACCOUNT}" -o none
  echo "Granted Storage Blob Data Contributor on the tfstate storage account."
fi

TENANT_ID=$(az account show --query tenantId -o tsv)

if [[ "$SET_GITHUB_SECRETS" == "true" ]]; then
  echo
  echo "-- Setting GitHub repo secrets via gh --"
  gh secret set AZURE_CLIENT_ID --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --body "$APP_ID"
  gh secret set AZURE_TENANT_ID --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --body "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --body "$SUBSCRIPTION_ID"
  echo "Set AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID on ${GITHUB_OWNER}/${GITHUB_REPO}."
  echo "ALLOWED_IP_RANGES and name_prefix are still yours to set (not automated — see below)."
fi

cat <<EOF

== Done. Set these GitHub repo secrets (Settings → Secrets and variables → Actions) ==
$( [[ "$SET_GITHUB_SECRETS" == "true" ]] && echo "(AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_SUBSCRIPTION_ID were already set via gh above)" )

  AZURE_CLIENT_ID         $APP_ID
  AZURE_TENANT_ID         $TENANT_ID
  AZURE_SUBSCRIPTION_ID   $SUBSCRIPTION_ID
  ALLOWED_IP_RANGES       ["<your office/VPN egress ranges>"]  — not automated, pick your own

Then set name_prefix = "$NAME_PREFIX" in examples/standalone/terraform.tfvars,
and if you changed any of the state storage / app registration names from
the defaults, update examples/standalone/versions.tf's backend block to match.
EOF
