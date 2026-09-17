#!/usr/bin/env bash
# Shared helpers sourced by every scan script and by security-gate.sh.
# Not meant to be executed directly.

set -o pipefail

# Resolve the repository root regardless of where a script is invoked from.
sec_repo_root() {
  git -C "$(dirname "${BASH_SOURCE[1]:-$0}")" rev-parse --show-toplevel 2>/dev/null \
    || (cd "$(dirname "${BASH_SOURCE[1]:-$0}")/../.." && pwd)
}

SEC_REPO_ROOT="$(sec_repo_root)"
SEC_REPORTS_DIR="${SEC_REPO_ROOT}/security/reports"

sec_log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
sec_info() { sec_log "INFO  $*"; }
sec_warn() { sec_log "WARN  $*"; }
sec_err()  { sec_log "ERROR $*"; }

# Writes a normalized report envelope shared by all scanners so the policy
# engine (security-gate.sh) only has to understand one schema.
#
# Args: scanner_name status(completed|tool_missing|error) out_file counts_json details_json
sec_write_report() {
  local scanner="$1" status="$2" out_file="$3" counts_json="$4" details_json="$5"
  local generated_at
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -n \
    --arg scanner "$scanner" \
    --arg status "$status" \
    --arg generated_at "$generated_at" \
    --argjson findings "$counts_json" \
    --argjson details "$details_json" \
    '{
      scanner: $scanner,
      status: $status,
      generated_at: $generated_at,
      findings: $findings,
      details: $details
    }' > "$out_file"

  sec_info "wrote report: $out_file (status=$status)"
}

# Checks whether a binary exists on PATH; returns 0/1.
sec_tool_available() {
  command -v "$1" >/dev/null 2>&1
}
