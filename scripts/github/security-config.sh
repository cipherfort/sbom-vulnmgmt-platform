#!/usr/bin/env bash
# Create (or find) the org code security configuration cps-sbom-baseline,
# attach it to every repository in the org and make it the default for new
# ones, so every repo has a dependency graph for the collector to export.
#
#   scripts/github/security-config.sh --org <org>
#   scripts/github/security-config.sh --org <org> --include-configured
#
# Needs an org owner or security manager, with a token that has write:org
# (`gh auth refresh -s write:org`). Read-only until it prints "Applying".
#
# Two deliberate departures from "set everything":
#   * Paid features are not_set, not disabled. With enforcement on, "disabled"
#     would switch GHAS code scanning / secret protection OFF in repos that use
#     them today. not_set leaves each repo's existing choice alone.
#   * The attach uses scope all_without_configurations, so repos already on
#     another configuration keep it. The script lists those configurations
#     first; add the three settings below to them, or re-run with
#     --include-configured to overwrite them.
set -euo pipefail

NAME=cps-sbom-baseline
ORG="" INCLUDE_CONFIGURED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --include-configured) INCLUDE_CONFIGURED=true; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
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
  ID=$(api -X POST "/orgs/$ORG/code-security/configurations" --input - --jq .id <<JSON
{
  "name": "$NAME",
  "description": "CPS SBOM platform: every repo has a dependency graph (docs/adr/0001-team-sbom-platform.md).",
  "dependency_graph": "enabled",
  "dependency_graph_autosubmit_action": "enabled",
  "dependabot_alerts": "enabled",
  "dependabot_security_updates": "not_set",
  "code_security": "not_set",
  "secret_protection": "not_set",
  "enforcement": "enforced"
}
JSON
)
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
