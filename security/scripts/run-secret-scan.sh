#!/usr/bin/env bash
# Secret scanning via Gitleaks — scans the full git history plus working
# tree so a secret that was committed and later removed still trips the
# gate (deleting a leaked credential from HEAD does not rotate it).
#
# Output: security/reports/secrets/gitleaks-raw.json
#         security/reports/secrets/secret-scan-report.json (normalized)
#
# Exit codes:
#   0 - scan completed (regardless of findings)
#   1 - gitleaks not installed
#   2 - unexpected error
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

OUT_DIR="${SEC_REPORTS_DIR}/secrets"
RAW_FILE="${OUT_DIR}/gitleaks-raw.json"
REPORT_FILE="${OUT_DIR}/secret-scan-report.json"

mkdir -p "$OUT_DIR"

if ! sec_tool_available gitleaks; then
  sec_warn "gitleaks is not installed on this machine."
  sec_warn "Install with: brew install gitleaks   (or) see https://github.com/gitleaks/gitleaks#installing"
  sec_write_report "gitleaks" "tool_missing" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0,"total_secrets":0}' \
    '[{"message":"gitleaks binary not found on PATH; scan did not run"}]'
  exit 1
fi

sec_info "Running gitleaks against ${SEC_REPO_ROOT}"

set +e
gitleaks detect \
  --source "$SEC_REPO_ROOT" \
  --config "${SEC_REPO_ROOT}/security/policy/gitleaks.toml" \
  --report-format json \
  --report-path "$RAW_FILE" \
  --no-banner \
  --redact
GITLEAKS_EXIT=$?
set -e

# gitleaks exit codes: 0 = no leaks found, 1 = leaks found, other = error.
if [[ $GITLEAKS_EXIT -gt 1 ]]; then
  sec_err "gitleaks exited with unexpected code ${GITLEAKS_EXIT}"
  sec_write_report "gitleaks" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0,"total_secrets":0}' \
    "[{\"message\":\"gitleaks exited with code ${GITLEAKS_EXIT}\"}]"
  exit 2
fi

if [[ ! -f "$RAW_FILE" ]]; then
  # No findings: gitleaks does not always write the report file when clean.
  echo '[]' > "$RAW_FILE"
fi

TOTAL=$(jq 'length' "$RAW_FILE" 2>/dev/null || echo 0)
DETAILS=$(jq '[.[] | {rule: .RuleID, file: .File, line: .StartLine, secretRedacted: .Secret}] | .[0:50]' "$RAW_FILE" 2>/dev/null || echo '[]')

# Any secret finding is treated as "high" by default for severity rollups;
# the gate itself uses block_on_any_finding for this scanner (zero tolerance).
COUNTS=$(jq -n --argjson total "$TOTAL" \
  '{critical:0, high:$total, medium:0, low:0, total_secrets:$total}')

sec_write_report "gitleaks" "completed" "$REPORT_FILE" "$COUNTS" "$DETAILS"
sec_info "Secret scan complete. Findings: ${TOTAL}"
exit 0
