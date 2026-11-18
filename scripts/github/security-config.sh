#!/usr/bin/env bash
# Turns on the dependency graph for every repo in the org: creates the code
# security configuration cps-sbom-baseline, attaches it to every repo without
# a configuration, and makes it the default for new repos.
#
#   scripts/github/security-config.sh --org <org> [--include-configured]
#
# Needs an org owner and a token with admin:org (gh auth refresh -s admin:org).
# Paid features are left not_set, so repos keep whatever they use today.
# --include-configured also replaces other configurations already attached.
set -euo pipefail

NAME=cps-sbom-baseline
ORG="" INCLUDE_CONFIGURED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --include-configured) INCLUDE_CONFIGURED=true; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ORG" ]] || { echo "--org is required" >&2; exit 2; }

api() { gh api -H "X-GitHub-Api-Version: 2026-03-10" "$@"; }

echo "Existing configurations in $ORG:"
api --paginate "/orgs/$ORG/code-security/configurations" \
  --jq '.[] | "  \(.id)\t\(.name)\tdependency_graph=\(.dependency_graph)\tdependabot_alerts=\(.dependabot_alerts)\tenforcement=\(.enforcement)"'

ID=$(api --paginate "/orgs/$ORG/code-security/configurations" --jq ".[] | select(.name == \"$NAME\") | .id")
if [[ -z "$ID" ]]; then
  body='{
  "name": "'"$NAME"'",
  "description": "CPS SBOM platform: every repo has a dependency graph (docs/design-decisions.md).",
  "dependency_graph": "enabled",
  "dependency_graph_autosubmit_action": "enabled",
  "dependabot_alerts": "enabled",
  "dependabot_security_updates": "not_set",
  "code_security": "not_set",
  "secret_protection": "not_set",
  "enforcement": "enforced"
}'
  # Orgs without Advanced Security reject these two fields, even as not_set.
  if ! ID=$(api -X POST "/orgs/$ORG/code-security/configurations" --input - --jq .id <<<"$body" 2>"${TMPDIR:-/tmp}/sbom-config.err"); then
    grep -q "unbundled Advanced Security" "${TMPDIR:-/tmp}/sbom-config.err" || { cat "${TMPDIR:-/tmp}/sbom-config.err" >&2; exit 1; }
    echo "No Advanced Security plan in $ORG: creating without the code_security / secret_protection settings"
    ID=$(jq 'del(.code_security, .secret_protection)' <<<"$body" \
      | api -X POST "/orgs/$ORG/code-security/configurations" --input - --jq .id)
  fi
  echo "Created $NAME (id $ID)"
else
  echo "Found $NAME (id $ID)"
fi

echo "Applying"
scope=all_without_configurations
[[ "$INCLUDE_CONFIGURED" == true ]] && scope=all
api -X POST "/orgs/$ORG/code-security/configurations/$ID/attach" -f scope="$scope" >/dev/null
api -X PUT "/orgs/$ORG/code-security/configurations/$ID/defaults" -f default_for_new_repos=all >/dev/null
echo "Attached $NAME to $ORG (scope $scope) and made it the default for new repositories"
echo "Attachment runs asynchronously; check Org > Settings > Code security > Configurations for progress."
