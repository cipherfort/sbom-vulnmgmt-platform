#!/usr/bin/env bash
# Symmetric undo for scripts/bootstrap.sh: removes the federated credential,
# the App Registration (which cascades its service principal), and both
# resource groups. Does NOT touch anything Terraform manages — run
# `terraform destroy` (from examples/standalone/) first if you have a live
# deployment, or you'll orphan it.
#
# Usage:
#   scripts/teardown-bootstrap.sh --name-prefix <prefix> [options] [--yes]
#
# Required:
#   --name-prefix <prefix>       Same value used with bootstrap.sh
#
# Optional (defaults shown, must match what bootstrap.sh actually used):
#   --tfstate-rg <name>          rg-tfstate-security-platform
#   --app-name <name>            sp-<name_prefix>-github-actions
#   --yes                        skip the confirmation prompt

set -euo pipefail

TFSTATE_RG="rg-tfstate-security-platform"
NAME_PREFIX=""
APP_NAME=""
CONFIRMED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name-prefix) NAME_PREFIX="$2"; shift 2 ;;
    --tfstate-rg) TFSTATE_RG="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --yes) CONFIRMED=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$NAME_PREFIX" ]]; then
  echo "Error: --name-prefix is required." >&2
  exit 1
fi

APP_NAME="${APP_NAME:-sp-${NAME_PREFIX}-github-actions}"
WORKLOAD_RG="rg-${NAME_PREFIX}"

echo "This will delete:"
echo "  - App Registration: $APP_NAME (and its service principal)"
echo "  - Resource group:   $WORKLOAD_RG"
echo "  - Resource group:   $TFSTATE_RG (including Terraform state storage)"
echo
echo "Make sure 'terraform destroy' (from examples/standalone/) has already run against any live deployment — this does not do that for you."
echo

if [[ "$CONFIRMED" != "true" ]]; then
  read -r -p "Type 'yes' to proceed: " REPLY
  if [[ "$REPLY" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [[ -n "$APP_ID" ]]; then
  az ad app delete --id "$APP_ID"
  echo "Deleted App Registration $APP_NAME."
else
  echo "App Registration $APP_NAME not found, skipping."
fi

if az group show --name "$WORKLOAD_RG" &>/dev/null; then
  az group delete --name "$WORKLOAD_RG" --yes --no-wait
  echo "Deleting resource group $WORKLOAD_RG (in background — check 'az group list' for completion)."
else
  echo "Resource group $WORKLOAD_RG not found, skipping."
fi

if az group show --name "$TFSTATE_RG" &>/dev/null; then
  az group delete --name "$TFSTATE_RG" --yes --no-wait
  echo "Deleting resource group $TFSTATE_RG (in background — check 'az group list' for completion)."
else
  echo "Resource group $TFSTATE_RG not found, skipping."
fi
