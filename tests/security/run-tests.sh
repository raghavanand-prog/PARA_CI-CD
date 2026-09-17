#!/usr/bin/env bash
# Test harness for the security-gate policy engine itself.
#
# This does NOT test the scanners (semgrep/gitleaks/checkov/trivy) — it
# tests security-gate.sh's decision logic against controlled fixture
# reports under tests/security/fixtures/, verifying:
#   - a clean set of reports PASSES
#   - a threshold violation FAILS
#   - a secret finding FAILS (zero tolerance)
#   - a missing report FAILS CLOSED
#   - a malformed (non-JSON) report FAILS CLOSED
#   - a scanner crash (status=error) FAILS CLOSED
#   - a scanner that never ran (status=tool_missing) FAILS CLOSED
#
# Usage: tests/security/run-tests.sh
# Exit code: 0 if every scenario behaved as expected, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATE="${REPO_ROOT}/security/scripts/security-gate.sh"
POLICY="${REPO_ROOT}/security/policy/security-policy.yaml"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

PASS_COUNT=0
FAIL_COUNT=0

# Args: name, fixture_dir, expected_exit_code, [grep_pattern_expected_in_output]
run_case() {
  local name="$1" fixture="$2" expected_exit="$3" expect_grep="${4:-}"
  local output exit_code

  output=$(SECURITY_GATE_REPORTS_DIR="${FIXTURES_DIR}/${fixture}" "$GATE" "$POLICY" 2>&1)
  exit_code=$?

  local ok=true
  if [[ "$exit_code" -ne "$expected_exit" ]]; then
    ok=false
    echo "  expected exit ${expected_exit}, got ${exit_code}"
  fi

  if [[ -n "$expect_grep" ]] && ! echo "$output" | grep -q -- "$expect_grep"; then
    ok=false
    echo "  expected output to contain: ${expect_grep}"
  fi

  if [[ "$ok" == "true" ]]; then
    echo "PASS: ${name}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: ${name}"
    echo "---- gate output ----"
    echo "$output"
    echo "----------------------"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

echo "Running security-gate.sh policy engine test suite"
echo "===================================================="

run_case "clean reports pass the gate"              "pass"                  0 "OVERALL RESULT: PASS"
run_case "critical/high threshold violation blocks"  "fail_threshold"        1 "OVERALL RESULT: FAIL"
run_case "any secret finding blocks (zero tolerance)" "fail_secret"          1 "zero tolerance"
run_case "missing report fails closed"               "fail_missing_report"  1 "report file missing"
run_case "malformed (non-JSON) report fails closed"  "fail_malformed_report" 1 "not valid JSON"
run_case "scanner crash (status=error) fails closed" "fail_scanner_crash"   1 "scanner status is 'error'"
run_case "scanner never ran (tool_missing) fails closed" "fail_tool_missing" 1 "scanner status is 'tool_missing'"

echo "===================================================="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
