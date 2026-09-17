#!/usr/bin/env bash
# security-gate.sh — the policy engine.
#
# Reads every normalized scanner report under security/reports/, evaluates
# each one against the thresholds in security/policy/security-policy.yaml,
# and prints a PASS/FAIL summary. Exits non-zero if ANY category violates
# policy. This script is what CodeBuild (see ci/buildspec.yml) and the
# GitHub Actions workflow (see .github/workflows) actually gate on — nothing
# downstream (ECR push, ECS deploy) runs unless this script exits 0.
#
# Fail-closed semantics (see policy `gate` section):
#   - A missing report file            -> violation
#   - A report that isn't valid JSON   -> violation
#   - A report whose status is not
#     "completed" (tool_missing/error) -> violation
#   - An invalid/unparseable policy    -> hard abort (exit 3), gate can't run
#
# Exit codes:
#   0 - all enabled categories PASS
#   1 - one or more categories FAIL (policy violation)
#   3 - the gate itself could not run (bad policy file, missing dependencies)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

POLICY_FILE="${1:-${SEC_REPO_ROOT}/security/policy/security-policy.yaml}"
# SECURITY_GATE_REPORTS_DIR lets the test harness (tests/security/) point the
# gate at isolated fixture reports without touching the real reports/ tree.
REPORTS_DIR="${SECURITY_GATE_REPORTS_DIR:-${SEC_REPO_ROOT}/security/reports}"

for bin in jq yq; do
  if ! sec_tool_available "$bin"; then
    sec_err "Required tool '$bin' is not installed. The gate cannot run without it."
    exit 3
  fi
done

if [[ ! -f "$POLICY_FILE" ]]; then
  sec_err "Policy file not found: $POLICY_FILE"
  exit 3
fi

# Support both the Go (mikefarah) yq (`yq -o=json`) and the Python
# (kislyuk) yq (`yq` emits JSON by default) since either may be installed.
if yq --help 2>&1 | grep -q -- '-o, --output-format'; then
  POLICY_JSON=$(yq -o=json '.' "$POLICY_FILE" 2>/dev/null) || {
    sec_err "Policy file is not valid YAML: $POLICY_FILE"
    exit 3
  }
else
  POLICY_JSON=$(yq '.' "$POLICY_FILE" 2>/dev/null) || {
    sec_err "Policy file is not valid YAML: $POLICY_FILE"
    exit 3
  }
fi

if ! echo "$POLICY_JSON" | jq -e '.version and .sast and .dependencies and .secrets and .iac and .container and .gate' >/dev/null 2>&1; then
  sec_err "Policy file is missing required top-level sections (version/sast/dependencies/secrets/iac/container/gate)"
  exit 3
fi

FAIL_CLOSED_MISSING=$(echo "$POLICY_JSON" | jq -r '.gate.fail_closed_on_missing_report // true')
FAIL_CLOSED_CRASH=$(echo "$POLICY_JSON" | jq -r '.gate.fail_closed_on_scanner_crash // true')
if [[ -n "${SECURITY_GATE_REPORTS_DIR:-}" ]]; then
  SUMMARY_DIR="${SECURITY_GATE_REPORTS_DIR}/summary"
else
  SUMMARY_DIR="${SEC_REPO_ROOT}/$(echo "$POLICY_JSON" | jq -r '.gate.summary_dir // "security/reports/summary"')"
fi
mkdir -p "$SUMMARY_DIR"

GATE_PASS=true
declare -a ROW_LABELS=()
declare -a ROW_STATUS=()
declare -a ROW_DETAIL=()
CATEGORY_RESULTS_JSON="[]"

# ---------------------------------------------------------------------------
# add_row: records one line of the summary table and folds it into the
# machine-readable results array.
# ---------------------------------------------------------------------------
add_row() {
  local label="$1" status="$2" detail="$3" category="$4"
  ROW_LABELS+=("$label")
  ROW_STATUS+=("$status")
  ROW_DETAIL+=("$detail")
  CATEGORY_RESULTS_JSON=$(jq -n \
    --argjson existing "$CATEGORY_RESULTS_JSON" \
    --arg category "$category" \
    --arg status "$status" \
    --arg detail "$detail" \
    '$existing + [{category: $category, status: $status, detail: $detail}]')
}

# ---------------------------------------------------------------------------
# load_report: reads and validates a scanner's normalized JSON report.
# Sets globals REPORT_VALID, REPORT_REASON, and REPORT_JSON (the parsed
# report contents on success). Must NOT be called via command substitution
# (that would run it in a subshell and lose the globals) — call it directly.
# ---------------------------------------------------------------------------
load_report() {
  local path="$1"
  REPORT_VALID=true
  REPORT_REASON=""
  REPORT_JSON=""

  if [[ ! -f "$path" ]]; then
    REPORT_VALID=false
    REPORT_REASON="report file missing: $path"
    return
  fi

  if ! jq -e . "$path" >/dev/null 2>&1; then
    REPORT_VALID=false
    REPORT_REASON="report is not valid JSON: $path"
    return
  fi

  local status
  status=$(jq -r '.status // "unknown"' "$path")
  if [[ "$status" != "completed" ]]; then
    REPORT_VALID=false
    REPORT_REASON="scanner status is '${status}' (expected 'completed'): $path"
    return
  fi

  if ! jq -e '.findings.critical != null and .findings.high != null and .findings.medium != null and .findings.low != null' "$path" >/dev/null 2>&1; then
    REPORT_VALID=false
    REPORT_REASON="report is missing findings counts: $path"
    return
  fi

  REPORT_JSON="$(cat "$path")"
}

# ---------------------------------------------------------------------------
# evaluate_severity_category: generic evaluator for sast/dependencies/iac/container
# ---------------------------------------------------------------------------
evaluate_severity_category() {
  local category="$1" label="$2" report_path="$3"
  local enabled
  enabled=$(echo "$POLICY_JSON" | jq -r ".${category}.enabled // true")

  if [[ "$enabled" != "true" ]]; then
    add_row "$label" "SKIPPED" "disabled in policy" "$category"
    return
  fi

  load_report "$report_path"

  if [[ "$REPORT_VALID" != "true" ]]; then
    local fail_closed="$FAIL_CLOSED_MISSING"
    if [[ "$REPORT_REASON" == *"status is"* ]]; then
      fail_closed="$FAIL_CLOSED_CRASH"
    fi
    if [[ "$fail_closed" == "true" ]]; then
      GATE_PASS=false
      add_row "$label" "FAIL" "$REPORT_REASON (fail-closed)" "$category"
    else
      add_row "$label" "SKIPPED" "$REPORT_REASON (fail-open per policy)" "$category"
    fi
    return
  fi

  local critical high medium low
  critical=$(echo "$REPORT_JSON" | jq -r '.findings.critical')
  high=$(echo "$REPORT_JSON" | jq -r '.findings.high')
  medium=$(echo "$REPORT_JSON" | jq -r '.findings.medium')
  low=$(echo "$REPORT_JSON" | jq -r '.findings.low')

  local max_critical max_high max_medium max_low
  max_critical=$(echo "$POLICY_JSON" | jq -r ".${category}.block_on_severity.critical")
  max_high=$(echo "$POLICY_JSON" | jq -r ".${category}.block_on_severity.high")
  max_medium=$(echo "$POLICY_JSON" | jq -r ".${category}.block_on_severity.medium")
  max_low=$(echo "$POLICY_JSON" | jq -r ".${category}.block_on_severity.low")

  local violations=()
  # -1 threshold means "unlimited / not enforced".
  [[ "$max_critical" != "-1" && "$critical" -gt "$max_critical" ]] && violations+=("critical ${critical}>${max_critical}")
  [[ "$max_high" != "-1" && "$high" -gt "$max_high" ]] && violations+=("high ${high}>${max_high}")
  [[ "$max_medium" != "-1" && "$medium" -gt "$max_medium" ]] && violations+=("medium ${medium}>${max_medium}")
  [[ "$max_low" != "-1" && "$low" -gt "$max_low" ]] && violations+=("low ${low}>${max_low}")

  local detail="critical=${critical} high=${high} medium=${medium} low=${low}"
  if [[ ${#violations[@]} -eq 0 ]]; then
    add_row "$label" "PASS" "$detail" "$category"
  else
    GATE_PASS=false
    local viol_str
    viol_str=$(IFS=, ; echo "${violations[*]}")
    add_row "$label" "FAIL" "${detail} | violations: ${viol_str}" "$category"
  fi
}

# ---------------------------------------------------------------------------
# evaluate_secrets: zero-tolerance category with its own shape.
# ---------------------------------------------------------------------------
evaluate_secrets() {
  local enabled
  enabled=$(echo "$POLICY_JSON" | jq -r '.secrets.enabled // true')
  if [[ "$enabled" != "true" ]]; then
    add_row "Secrets (Gitleaks)" "SKIPPED" "disabled in policy" "secrets"
    return
  fi

  local report_path="${REPORTS_DIR}/secrets/secret-scan-report.json"
  load_report "$report_path"

  if [[ "$REPORT_VALID" != "true" ]]; then
    local fail_closed="$FAIL_CLOSED_MISSING"
    if [[ "$REPORT_REASON" == *"status is"* ]]; then
      fail_closed="$FAIL_CLOSED_CRASH"
    fi
    if [[ "$fail_closed" == "true" ]]; then
      GATE_PASS=false
      add_row "Secrets (Gitleaks)" "FAIL" "$REPORT_REASON (fail-closed)" "secrets"
    else
      add_row "Secrets (Gitleaks)" "SKIPPED" "$REPORT_REASON (fail-open per policy)" "secrets"
    fi
    return
  fi

  local total
  total=$(echo "$REPORT_JSON" | jq -r '.findings.total_secrets // (.findings.high // 0)')
  local block_on_any
  block_on_any=$(echo "$POLICY_JSON" | jq -r '.secrets.block_on_any_finding // true')

  if [[ "$block_on_any" == "true" && "$total" -gt 0 ]]; then
    GATE_PASS=false
    add_row "Secrets (Gitleaks)" "FAIL" "secrets_found=${total} (zero tolerance)" "secrets"
  else
    add_row "Secrets (Gitleaks)" "PASS" "secrets_found=${total}" "secrets"
  fi
}

# ---------------------------------------------------------------------------
# Run all evaluations
# ---------------------------------------------------------------------------
evaluate_severity_category "sast" "SAST (Semgrep)" "${REPORTS_DIR}/sast/semgrep-report.json"
evaluate_severity_category "dependencies" "Dependencies (npm audit / OWASP DC)" "${REPORTS_DIR}/dependencies/dependency-scan-report.json"
evaluate_secrets
evaluate_severity_category "iac" "IaC (Checkov)" "${REPORTS_DIR}/iac/iac-scan-report.json"
evaluate_severity_category "container" "Container (Trivy)" "${REPORTS_DIR}/container/container-scan-report.json"

# ---------------------------------------------------------------------------
# Render human-readable summary table
# ---------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OVERALL="PASS"
[[ "$GATE_PASS" == "false" ]] && OVERALL="FAIL"

{
  echo "=================================================================="
  echo "                    SECURITY GATE RESULT"
  echo "=================================================================="
  printf "%-38s %-10s %s\n" "CATEGORY" "STATUS" "DETAIL"
  echo "------------------------------------------------------------------"
  for i in "${!ROW_LABELS[@]}"; do
    printf "%-38s %-10s %s\n" "${ROW_LABELS[$i]}" "${ROW_STATUS[$i]}" "${ROW_DETAIL[$i]}"
  done
  echo "------------------------------------------------------------------"
  echo "OVERALL RESULT: ${OVERALL}"
  echo "Evaluated at:   ${TIMESTAMP}"
  echo "Policy file:    ${POLICY_FILE}"
  echo "=================================================================="
} | tee "${SUMMARY_DIR}/security-gate-summary.txt"

jq -n \
  --arg overall "$OVERALL" \
  --arg timestamp "$TIMESTAMP" \
  --arg policy_file "$POLICY_FILE" \
  --argjson categories "$CATEGORY_RESULTS_JSON" \
  '{overall: $overall, generated_at: $timestamp, policy_file: $policy_file, categories: $categories}' \
  > "${SUMMARY_DIR}/security-gate-summary.json"

sec_info "Summary written to ${SUMMARY_DIR}/security-gate-summary.{txt,json}"

if [[ "$GATE_PASS" == "true" ]]; then
  sec_info "SECURITY GATE: PASS — deployment may proceed"
  exit 0
else
  sec_err "SECURITY GATE: FAIL — deployment blocked"
  exit 1
fi
