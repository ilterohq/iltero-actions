#!/bin/bash
#
# The CLI's check of one stage of a change, and its answer to whether a
# unit's record requires a stage, used for both infrastructure as code (IaC)
# changes and container images. Source this file after common.sh.

# The exit code of `iltero record in-scope` and `iltero record verify` for a
# record that does not verify: the record, or a file it cites, changed.
readonly RECORD_DOES_NOT_VERIFY_STATUS=9

# Runs the CLI with ARGS, using the evaluator that `setup` installed and the
# scanner folder that install_scanners fills. Prints its output with workflow
# commands paused and keeps a copy in LOG for the summary. Returns the CLI's
# exit code.
run_cli_logged() {
  local log="$1"
  shift
  local cli tools scanners status=0
  # Each lookup returns on failure itself: callers may run this where bash
  # ignores set -e.
  cli="$(cli_path)" || return 1
  tools="$(tools_dir)" || return 1
  scanners="$(scanner_dir)" || return 1
  ILTERO_OPA_PATH="${tools}/bin/opa" ILTERO_CACHE_DIR="${scanners}" "${cli}" "$@" > "${log}" 2>&1 || status=$?
  print_untrusted "${log}"
  return "${status}"
}

# The exit codes of `iltero record in-scope`: the stage is in the record's
# scope, or out of it. Every other code is an error.
readonly IN_SCOPE_STATUS=0
readonly OUT_OF_SCOPE_STATUS=3
# Prints "true" when STAGE is in the scope of the record of UNIT in OUT, and
# "false" when it is not, as the CLI answers. Keeps the CLI's answer in
# WORK/in-scope-STAGE.txt, and shows it on stderr with workflow commands
# paused, so only "true" or "false" is printed on stdout. Exits with the CLI's
# own code on any other answer.
record_requires_stage() {
  local work="$1"
  local out="$2"
  local unit="$3"
  local stage="$4"
  local status=0
  run_cli_logged "${work}/in-scope-${stage}.txt" record in-scope "${out}/units/${unit}" --stage="${stage}" >&2 \
    || status=$?
  case "${status}" in
    "${IN_SCOPE_STATUS}") echo true ;;
    "${OUT_OF_SCOPE_STATUS}") echo false ;;
    *) exit_with_error "${status}" "The CLI could not say whether the record of unit '${unit}' requires the ${stage//_/-} stage. See the CLI's output in the log." ;;
  esac
}

# Prints the summary cell for a record whose scope the CLI could not give,
# from the CLI's exit code STATUS.
record_scope_failure() {
  local status="$1"
  if [[ "${status}" -eq "${RECORD_DOES_NOT_VERIFY_STATUS}" ]]; then
    echo "record does not verify"
  else
    echo "record unreadable"
  fi
}

# The exit code of `iltero scanners install` when a scanner, or the scanner
# folder, fails the CLI's integrity check against the pinned digests.
readonly SCANNER_INTEGRITY_FAILED_STATUS=9
# The exit code of `iltero scanners install` when it could not download a
# scanner, or the CLI pins none for this runner.
readonly SCANNER_NOT_INSTALLED_STATUS=4

# Installs the scanners the CLI pins, for a run the server opens: its stages
# run them when the run's settings require them. Keeps the CLI's output in LOG.
# Stops with the CLI's exit code when the install fails.
install_scanners() {
  local log="$1"
  local status=0
  echo "::group::Install the scanners"
  run_cli_logged "${log}" scanners install || status=$?
  echo "::endgroup::"
  case "${status}" in
    0) ;;
    "${SCANNER_INTEGRITY_FAILED_STATUS}")
      exit_with_error "${status}" "A scanner or the scanner folder failed the Iltero CLI's integrity check against the pinned digests (fingerprints). The CLI's message above names the file or folder. Find out why before you run the job again." ;;
    "${SCANNER_NOT_INSTALLED_STATUS}")
      exit_with_error "${status}" "The Iltero CLI could not install the scanners it pins. The CLI's message above says why. When a download failed, the job must reach github.com, pypi.org and files.pythonhosted.org, through the proxy in HTTPS_PROXY when the runner uses one." ;;
    *)
      exit_with_error "${status}" "The Iltero CLI could not install the scanners it pins. The CLI's message above says why." ;;
  esac
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
