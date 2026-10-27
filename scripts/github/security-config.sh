#!/usr/bin/env bash
# Create (or find) the enterprise code security configuration cps-sbom-baseline
# and apply it — Flow 1 / Phase 1 step 1 and Phase 2 of the design doc.
#
#   scripts/github/security-config.sh --enterprise <slug> --pilot-org <org>   # Phase 1: one org
#   scripts/github/security-config.sh --enterprise <slug> --enterprise-wide   # Phase 2: every repo + default for new repos
#
# Needs a token with admin:enterprise (an enterprise owner's `gh auth login
# --scopes admin:enterprise`). Read-only until it prints "Applying".
#
# Two deliberate departures from "set everything":
#   * Paid features are not_set, not disabled. With enforcement on, "disabled"
#     would switch GHAS code scanning / secret protection OFF in repos that use
#     them today. not_set leaves each repo's existing choice alone.
#   * --enterprise-wide attaches with scope all_without_configurations, so repos
#     already on another configuration keep it. The script lists those
#     configurations first; add the three settings below to them, or re-run
#     with --include-configured to overwrite them.
set -euo pipefail

NAME=cps-sbom-baseline
ENTERPRISE="" PILOT_ORG="" WIDE=false INCLUDE_CONFIGURED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enterprise) ENTERPRISE="$2"; shift 2 ;;
    --pilot-org) PILOT_ORG="$2"; shift 2 ;;
    --enterprise-wide) WIDE=true; shift ;;
    --include-configured) INCLUDE_CONFIGURED=true; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$ENTERPRISE" ]] || { echo "--enterprise is required" >&2; exit 2; }
[[ -n "$PILOT_ORG" || "$WIDE" == true ]] || { echo "Pass --pilot-org <org> or --enterprise-wide" >&2; exit 2; }

api() { gh api -H "X-GitHub-Api-Version: 2026-03-10" "$@"; }

echo "Existing enterprise configurations:"
api --paginate "/enterprises/$ENTERPRISE/code-security/configurations" \
  --jq '.[] | "  \(.id)\t\(.name)\tdependency_graph=\(.dependency_graph)\tdependabot_alerts=\(.dependabot_alerts)\tenforcement=\(.enforcement)"'

ID=$(api --paginate "/enterprises/$ENTERPRISE/code-security/configurations" --jq ".[] | select(.name == \"$NAME\") | .id")
if [[ -z "$ID" ]]; then
  ID=$(api -X POST "/enterprises/$ENTERPRISE/code-security/configurations" --input - --jq .id <<JSON
{
  "name": "$NAME",
  "description": "CPS enterprise SBOM platform: every repo has a dependency graph (ADR-0002).",
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
if [[ -n "$PILOT_ORG" ]]; then
  # Org-level attach of an enterprise configuration. Verified in the docs for
  # org configurations; if this 404s for an enterprise-owned configuration,
  # apply it to the org in the UI (Enterprise > Settings > Code security).
  api -X POST "/orgs/$PILOT_ORG/code-security/configurations/$ID/attach" -f scope=all >/dev/null
  echo "Attached $NAME to every repository in $PILOT_ORG"
fi
if [[ "$WIDE" == true ]]; then
  scope=all_without_configurations
  [[ "$INCLUDE_CONFIGURED" == true ]] && scope=all
  api -X POST "/enterprises/$ENTERPRISE/code-security/configurations/$ID/attach" -f scope="$scope" >/dev/null
  api -X PUT "/enterprises/$ENTERPRISE/code-security/configurations/$ID/defaults" -f default_for_new_repos=all >/dev/null
  echo "Attached $NAME enterprise-wide (scope $scope) and made it the default for new repositories"
fi
echo "Attachment runs asynchronously; check Enterprise > Settings > Code security > Configurations for progress."
