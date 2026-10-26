#!/bin/bash
#
# Packs and checks each unit's Change Assurance Record.
#
# Usage:
#   verify.sh check            Refuse untrusted events; check that setup ran.
#   verify.sh run RECORDS_DIRECTORY      For each unit: iltero car build, then iltero car verify.
#
# Run from the stack's working directory, with the RECORDS_DIRECTORY the deploy action
# wrote. Every unit is checked; the step fails when any unit fails. When
# WRITE_REPORT is true, the CLI also writes a report of each unit's record bundle.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"

cmd_check() {
  refuse_untrusted_event
  cli_path > /dev/null
}

# Runs one CLI command. Prints its output and keeps a copy for the summary.
# Returns the CLI's exit code.
run_cli() {
  local log="$1"
  shift
  local cli tools status=0
  cli="$(cli_path)"
  tools="$(tools_dir)"
  ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" "$@" > "${log}" 2>&1 || status=$?
  print_untrusted "${log}"
  return "${status}"
}

cmd_run() {
  local out="$1"
  [[ -d "${out}" ]] || die "The records directory '${out}' does not exist. Pass the deploy action's records-directory."
  local report
  report="$(report_enabled)"
  local work_root="${RUNNER_TEMP}/iltero-verify"
  local units="${work_root}/units.tsv"
  local reports="${work_root}/reports"
  mkdir -p "${work_root}"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi
  list_checked_units "${units}"

  local summary="${work_root}/summary.md" details="${work_root}/details.md"
  {
    echo "## Iltero records"
    echo
    echo "| Unit | Build | Verify |"
    echo "| --- | --- | --- |"
  } > "${summary}"
  : > "${details}"

  local name dir work build verify failed=0 bundles
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    mkdir -p "${work}"
    echo "::group::${name}"
    build=0
    verify="-"
    run_cli "${work}/build.txt" car build --out="${out}" --unit="${name}" || build=$?
    if [[ "${build}" -eq 0 ]]; then
      shopt -s nullglob
      bundles=("${out}/units/${name}"/car-*/)
      shopt -u nullglob
      if [[ "${#bundles[@]}" -ne 1 ]]; then
        echo "::error::Expected one record bundle for unit '${name}', found ${#bundles[@]}."
        verify="no bundle"
        failed=1
      else
        verify=0
        run_cli "${work}/verify.txt" car verify "${bundles[0]}" || verify=$?
        [[ "${verify}" -eq 0 ]] || failed=1
        verify="exit ${verify}"
      fi
    else
      failed=1
    fi
    echo "::endgroup::"
    echo "| ${name} | exit ${build} | ${verify} |" >> "${summary}"
    local step
    for step in build verify; do
      [[ -f "${work}/${step}.txt" ]] || continue
      details_block "${name}: ${step}" "${work}/${step}.txt" >> "${details}"
    done
    if [[ "${report}" == true && "${verify}" == exit* ]]; then
      write_report "${name}" "${bundles[0]}" "${reports}" "${details}" "${work}/report.txt"
    fi
  done < "${units}"

  {
    cat "${summary}"
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [[ "${failed}" -eq 0 ]] || die "One or more records failed to build or verify. See the job summary."
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    run) [[ $# -eq 1 ]] || die "Usage: verify.sh run RECORDS_DIRECTORY"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check | run RECORDS_DIRECTORY" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
