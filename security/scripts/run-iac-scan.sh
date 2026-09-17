#!/usr/bin/env bash
# Infrastructure-as-Code scanning via Checkov, run against terraform/.
#
# Output: security/reports/iac/checkov-raw.json
#         security/reports/iac/iac-scan-report.json (normalized)
#
# Exit codes:
#   0 - scan completed
#   1 - checkov not installed
#   2 - unexpected error
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

OUT_DIR="${SEC_REPORTS_DIR}/iac"
RAW_FILE="${OUT_DIR}/checkov-raw.json"
REPORT_FILE="${OUT_DIR}/iac-scan-report.json"
TARGET="${1:-${SEC_REPO_ROOT}/terraform}"

mkdir -p "$OUT_DIR"

if ! sec_tool_available checkov; then
  sec_warn "checkov is not installed on this machine."
  sec_warn "Install with: pip install checkov"
  sec_write_report "checkov" "tool_missing" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"checkov binary not found on PATH; scan did not run"}]'
  exit 1
fi

sec_info "Running checkov against ${TARGET}"

set +e
checkov \
  --directory "$TARGET" \
  --framework terraform \
  --output json \
  --output-file-path "$OUT_DIR" \
  --compact \
  --quiet
CHECKOV_EXIT=$?
set -e

# checkov writes results_json.json into --output-file-path
if [[ -f "${OUT_DIR}/results_json.json" ]]; then
  mv "${OUT_DIR}/results_json.json" "$RAW_FILE"
fi

# checkov exit codes: 0 = no failed checks, 1 = failed checks present.
if [[ $CHECKOV_EXIT -gt 1 ]]; then
  sec_err "checkov exited with unexpected code ${CHECKOV_EXIT}"
  sec_write_report "checkov" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    "[{\"message\":\"checkov exited with code ${CHECKOV_EXIT}\"}]"
  exit 2
fi

if [[ ! -s "$RAW_FILE" ]]; then
  sec_err "checkov produced no output file"
  sec_write_report "checkov" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"checkov produced no output"}]'
  exit 2
fi

# Checkov severities can be absent for some checks; default missing severity
# to MEDIUM so a check without an explicit severity is not silently ignored.
COUNTS=$(jq '
  (.results.failed_checks // []) as $failed |
  {
    critical: ([$failed[] | select((.severity // "MEDIUM") == "CRITICAL")] | length),
    high:     ([$failed[] | select((.severity // "MEDIUM") == "HIGH")] | length),
    medium:   ([$failed[] | select((.severity // "MEDIUM") == "MEDIUM")] | length),
    low:      ([$failed[] | select((.severity // "MEDIUM") == "LOW")] | length)
  }' "$RAW_FILE")

DETAILS=$(jq '[(.results.failed_checks // [])[] | {check_id: .check_id, resource: .resource, file: .file_path, severity: (.severity // "MEDIUM"), description: .check_name}] | .[0:50]' "$RAW_FILE")

sec_write_report "checkov" "completed" "$REPORT_FILE" "$COUNTS" "$DETAILS"
sec_info "IaC scan complete. Findings: $(echo "$COUNTS" | jq -c .)"
exit 0
