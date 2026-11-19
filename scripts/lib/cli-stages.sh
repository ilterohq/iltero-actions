#!/bin/bash
#
# The CLI's check of one stage of a change, used for both infrastructure as
# code (IaC) changes and container images. Source this file after common.sh.

# The exit code of `iltero record in-scope` and `iltero record verify` for a
# record that does not verify: the record, or a file it cites, changed. Used
# by the scripts that source this file.
# shellcheck disable=SC2034
readonly RECORD_DOES_NOT_VERIFY_STATUS=9

# Runs the CLI with ARGS, using the evaluator that `setup` installed. Prints its
# output with workflow commands paused and keeps a copy in LOG for the summary.
# Returns the CLI's exit code.
run_cli_logged() {
  local log="$1"
  shift
  local cli tools status=0
  # Each lookup returns on failure itself: callers may run this where bash
  # ignores set -e.
  cli="$(cli_path)" || return 1
  tools="$(tools_dir)" || return 1
  ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" "$@" > "${log}" 2>&1 || status=$?
  print_untrusted "${log}"
  return "${status}"
}

# Stops unless the input INPUT, whose value is PATH_VALUE, names a file.
require_named_file() {
  local input="$1"
  local path_value="$2"
  [[ -f "${path_value}" ]] || die "The ${input} input names no file: '${path_value}'."
}

# The CLI options for the scan-reports input, which add_scan_report_options
# fills.
SCAN_REPORT_OPTIONS=()

# Adds to SCAN_REPORT_OPTIONS the CLI's options for REPORTS, the value of the
# scan-reports input: one report per line, the scanner's name, a space, then
# the report's path. Blank lines are skipped. Stops on a line whose scanner is
# not one of SCANNERS, or whose report is not a file.
add_scan_report_options() {
  local reports="$1"
  shift
  local scanners=("$@")
  local line scanner report
  while IFS= read -r line; do
    line="$(trim "${line}")"
    [[ -n "${line}" ]] || continue
    scanner="${line%% *}"
    report="$(trim "${line#* }")"
    [[ " ${scanners[*]} " == *" ${scanner} "* && "${report}" != "${line}" && -n "${report}" ]] \
      || die "Each line of the scan-reports input must be a scanner (${scanners[*]}), a space and the report's path. One line is '${line}'."
    require_named_file scan-reports "${report}"
    SCAN_REPORT_OPTIONS+=(--scanner="${scanner}" --scanner-report="${report}")
  done <<< "${reports}"
}

# Runs one stage of the CLI's check of a KIND of change (iac or image), with
# the CLI's remaining arguments. Prints its output and keeps a copy in
# WORK/STAGE.txt. Returns the CLI's exit code.
check_change_stage() {
  local kind="$1"
  local work="$2"
  local stage="$3"
  shift 3
  run_cli_logged "${work}/${stage}.txt" "${kind}" check --stage="${stage}" "$@"
}
