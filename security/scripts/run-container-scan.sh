#!/usr/bin/env bash
# Container image scanning via Trivy.
#
# Usage: run-container-scan.sh <image-ref>
#   e.g. run-container-scan.sh secure-aws-cicd-demo-api:local
#
# Output: security/reports/container/trivy-raw.json
#         security/reports/container/container-scan-report.json (normalized)
#
# Exit codes:
#   0 - scan completed
#   1 - trivy not installed, or no image reference given
#   2 - unexpected error
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

OUT_DIR="${SEC_REPORTS_DIR}/container"
RAW_FILE="${OUT_DIR}/trivy-raw.json"
REPORT_FILE="${OUT_DIR}/container-scan-report.json"
IMAGE_REF="${1:-}"

mkdir -p "$OUT_DIR"

if [[ -z "$IMAGE_REF" ]]; then
  sec_err "No image reference supplied. Usage: run-container-scan.sh <image:tag>"
  sec_write_report "trivy" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"no image reference supplied to scan"}]'
  exit 1
fi

if ! sec_tool_available trivy; then
  sec_warn "trivy is not installed on this machine."
  sec_warn "Install with: brew install trivy   (or) see https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
  sec_write_report "trivy" "tool_missing" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"trivy binary not found on PATH; scan did not run"}]'
  exit 1
fi

sec_info "Running trivy image scan against ${IMAGE_REF}"

set +e
trivy image \
  --format json \
  --severity CRITICAL,HIGH,MEDIUM,LOW \
  --ignorefile "${SEC_REPO_ROOT}/security/policy/.trivyignore" \
  --output "$RAW_FILE" \
  --quiet \
  --exit-code 0 \
  "$IMAGE_REF"
TRIVY_EXIT=$?
set -e

if [[ $TRIVY_EXIT -ne 0 ]]; then
  sec_err "trivy exited with unexpected code ${TRIVY_EXIT}"
  sec_write_report "trivy" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    "[{\"message\":\"trivy exited with code ${TRIVY_EXIT}\"}]"
  exit 2
fi

if [[ ! -s "$RAW_FILE" ]]; then
  sec_err "trivy produced no output file"
  sec_write_report "trivy" "error" "$REPORT_FILE" \
    '{"critical":0,"high":0,"medium":0,"low":0}' \
    '[{"message":"trivy produced no output"}]'
  exit 2
fi

COUNTS=$(jq '
  ([.Results[]? .Vulnerabilities[]?]) as $vulns |
  {
    critical: ([$vulns[] | select(.Severity=="CRITICAL")] | length),
    high:     ([$vulns[] | select(.Severity=="HIGH")] | length),
    medium:   ([$vulns[] | select(.Severity=="MEDIUM")] | length),
    low:      ([$vulns[] | select(.Severity=="LOW")] | length)
  }' "$RAW_FILE")

DETAILS=$(jq '[.Results[]? .Vulnerabilities[]? | {id: .VulnerabilityID, pkg: .PkgName, installed: .InstalledVersion, fixed: .FixedVersion, severity: .Severity}] | .[0:50]' "$RAW_FILE")

sec_write_report "trivy" "completed" "$REPORT_FILE" "$COUNTS" "$DETAILS"
sec_info "Container scan complete. Findings: $(echo "$COUNTS" | jq -c .)"
exit 0
