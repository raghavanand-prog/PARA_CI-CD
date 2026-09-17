#!/usr/bin/env bash
# Software Composition Analysis: npm audit (fast, always available once
# node_modules exist) plus OWASP Dependency-Check if installed (deeper CVE
# database coverage, including transitive native/OS-level dependencies).
#
# Output: security/reports/dependencies/npm-audit-report.json
#         security/reports/dependencies/dependency-check-report.json (if tool present)
#         security/reports/dependencies/dependency-scan-report.json (normalized, combined)
#
# Exit codes:
#   0 - scan(s) completed
#   1 - no scanner could run at all (npm audit unavailable AND dependency-check unavailable)
#   2 - unexpected error
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

OUT_DIR="${SEC_REPORTS_DIR}/dependencies"
REPORT_FILE="${OUT_DIR}/dependency-scan-report.json"
APP_DIR="${1:-${SEC_REPO_ROOT}/app}"

mkdir -p "$OUT_DIR"

NPM_CRITICAL=0 NPM_HIGH=0 NPM_MEDIUM=0 NPM_LOW=0
NPM_RAN=false
DC_CRITICAL=0 DC_HIGH=0 DC_MEDIUM=0 DC_LOW=0
DC_RAN=false
DETAILS="[]"

# ---------------------------------------------------------------------------
# npm audit
# ---------------------------------------------------------------------------
if [[ -f "${APP_DIR}/package.json" ]] && sec_tool_available npm; then
  sec_info "Running npm audit in ${APP_DIR}"
  NPM_RAW="${OUT_DIR}/npm-audit-report.json"
  (cd "$APP_DIR" && npm audit --json > "$NPM_RAW" 2>/dev/null) || true

  if [[ -s "$NPM_RAW" ]] && jq -e . "$NPM_RAW" >/dev/null 2>&1; then
    NPM_RAN=true
    NPM_CRITICAL=$(jq '[.vulnerabilities[]? | select(.severity=="critical")] | length' "$NPM_RAW")
    NPM_HIGH=$(jq '[.vulnerabilities[]? | select(.severity=="high")] | length' "$NPM_RAW")
    NPM_MEDIUM=$(jq '[.vulnerabilities[]? | select(.severity=="moderate")] | length' "$NPM_RAW")
    NPM_LOW=$(jq '[.vulnerabilities[]? | select(.severity=="low")] | length' "$NPM_RAW")
    DETAILS=$(jq -n --argjson existing "$DETAILS" --slurpfile raw "$NPM_RAW" \
      '$existing + [$raw[0].vulnerabilities // {} | to_entries[] | {package: .key, severity: .value.severity, via: (.value.via | if type=="array" then [.[] | if type=="object" then .title else . end] else . end)}] ' 2>/dev/null || echo "$DETAILS")
  else
    sec_warn "npm audit produced no parseable output"
  fi
else
  sec_warn "npm not available or app/package.json missing; skipping npm audit"
fi

# ---------------------------------------------------------------------------
# OWASP Dependency-Check (optional, deeper scan)
# ---------------------------------------------------------------------------
if sec_tool_available dependency-check.sh || sec_tool_available dependency-check; then
  DC_BIN=$(command -v dependency-check.sh || command -v dependency-check)
  sec_info "Running OWASP Dependency-Check via ${DC_BIN}"
  DC_RAW="${OUT_DIR}/dependency-check-report.json"
  "$DC_BIN" --scan "$APP_DIR" --format JSON --out "$OUT_DIR" --project "secure-aws-cicd-demo-api" >/dev/null 2>&1 || true
  if [[ -f "${OUT_DIR}/dependency-check-report.json" ]] && jq -e . "${OUT_DIR}/dependency-check-report.json" >/dev/null 2>&1; then
    DC_RAN=true
    DC_CRITICAL=$(jq '[.dependencies[]?.vulnerabilities[]? | select(.severity=="CRITICAL")] | length' "$DC_RAW")
    DC_HIGH=$(jq '[.dependencies[]?.vulnerabilities[]? | select(.severity=="HIGH")] | length' "$DC_RAW")
    DC_MEDIUM=$(jq '[.dependencies[]?.vulnerabilities[]? | select(.severity=="MEDIUM")] | length' "$DC_RAW")
    DC_LOW=$(jq '[.dependencies[]?.vulnerabilities[]? | select(.severity=="LOW")] | length' "$DC_RAW")
  fi
else
  sec_warn "OWASP Dependency-Check not installed; relying on npm audit only."
  sec_warn "Install docs: https://jeremylong.github.io/DependencyCheck/dependency-check-cli/"
fi

if [[ "$NPM_RAN" == false && "$DC_RAN" == false ]]; then
  sec_write_report "dependency-scan" "tool_missing" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"neither npm audit nor OWASP Dependency-Check could be run"}]'
  exit 1
fi

CRITICAL=$((NPM_CRITICAL + DC_CRITICAL))
HIGH=$((NPM_HIGH + DC_HIGH))
MEDIUM=$((NPM_MEDIUM + DC_MEDIUM))
LOW=$((NPM_LOW + DC_LOW))

COUNTS=$(jq -n --argjson c "$CRITICAL" --argjson h "$HIGH" --argjson m "$MEDIUM" --argjson l "$LOW" \
  '{critical:$c, high:$h, medium:$m, low:$l}')

sec_write_report "dependency-scan" "completed" "$REPORT_FILE" "$COUNTS" "$DETAILS"
sec_info "Dependency scan complete. Findings: $(echo "$COUNTS" | jq -c .) (npm_ran=$NPM_RAN, dependency_check_ran=$DC_RAN)"
exit 0
