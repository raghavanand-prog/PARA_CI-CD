#!/usr/bin/env bash
# Static Application Security Testing via Semgrep.
#
# Output: security/reports/sast/semgrep-report.json (normalized envelope)
#         security/reports/sast/semgrep-raw.json     (raw semgrep output, if it ran)
#
# Exit codes:
#   0 - scan completed (regardless of findings; the GATE decides pass/fail,
#       not this script)
#   1 - the scanner tool is not installed / could not run
#   2 - unexpected error while running the scanner or writing the report
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

OUT_DIR="${SEC_REPORTS_DIR}/sast"
RAW_FILE="${OUT_DIR}/semgrep-raw.json"
REPORT_FILE="${OUT_DIR}/semgrep-report.json"
TARGET="${1:-${SEC_REPO_ROOT}/app/src}"

mkdir -p "$OUT_DIR"

if ! sec_tool_available semgrep; then
  sec_warn "semgrep is not installed on this machine."
  sec_warn "Install with: pip install semgrep   (or) brew install semgrep"
  sec_write_report "semgrep" "tool_missing" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"semgrep binary not found on PATH; scan did not run"}]'
  exit 1
fi

sec_info "Running semgrep against: ${TARGET}"

set +e
semgrep scan \
  --config auto \
  --config p/security-audit \
  --config p/nodejsscan \
  --json \
  --output "$RAW_FILE" \
  --error \
  --quiet \
  "$TARGET"
SEMGREP_EXIT=$?
set -e

# semgrep exit codes: 0 = no findings, 1 = findings present (with --error),
# >1 = actual tool error. Both 0 and 1 mean "the scan ran successfully".
if [[ $SEMGREP_EXIT -gt 1 ]]; then
  sec_err "semgrep exited with unexpected code ${SEMGREP_EXIT}"
  sec_write_report "semgrep" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    "[{\"message\":\"semgrep exited with code ${SEMGREP_EXIT}\"}]"
  exit 2
fi

if [[ ! -s "$RAW_FILE" ]]; then
  sec_err "semgrep produced no output file"
  sec_write_report "semgrep" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"semgrep produced no output"}]'
  exit 2
fi

# Semgrep severities: ERROR (treat as high), WARNING (medium), INFO (low).
# Any rule tagged security + ERROR is elevated to CRITICAL.
COUNTS=$(jq '
  {
    critical: ([.results[]? | select(.extra.severity=="ERROR" and ((.extra.metadata.confidence // "") == "HIGH" or (.extra.metadata.cwe // null) != null))] | length),
    high: (([.results[]? | select(.extra.severity=="ERROR")] | length) - ([.results[]? | select(.extra.severity=="ERROR" and ((.extra.metadata.confidence // "") == "HIGH" or (.extra.metadata.cwe // null) != null))] | length)),
    medium: ([.results[]? | select(.extra.severity=="WARNING")] | length),
    low: ([.results[]? | select(.extra.severity=="INFO")] | length)
  }' "$RAW_FILE")

DETAILS=$(jq '[.results[]? | {rule: .check_id, path: .path, line: .start.line, severity: .extra.severity, message: .extra.message}] | .[0:50]' "$RAW_FILE")

sec_write_report "semgrep" "completed" "$REPORT_FILE" "$COUNTS" "$DETAILS"

sec_info "SAST scan complete. Findings: $(echo "$COUNTS" | jq -c .)"
exit 0
