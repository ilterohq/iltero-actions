#!/bin/bash
#
# Builds each unit's record bundle, then checks that the record and the files
# it cites are unchanged. With RUN_STATEMENT, the CLI also checks each record
# against the run statement the server signed when the run ended.
#
# Usage:
#   iac/verify.sh check                  Refuse untrusted events; check that setup ran.
#   iac/verify.sh run RECORDS_DIRECTORY  For each unit: iltero record build, then
#                                        iltero record verify.
#
# Run from the project's directory, with the RECORDS_DIRECTORY the
# deploy or record-iac action wrote. Every unit is checked, or only UNIT when
# it is set; the step fails when any unit fails. When WRITE_REPORT is true, the
# CLI also writes a report of each unit's record bundle.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"

# Prints the summary word for `iltero record verify`, from its exit code
# STATUS: "verified", "does not verify" when the CLI exits with
# RECORD_DOES_NOT_VERIFY_STATUS, and "could not verify" for any other failure.
verify_result() {
  local status="$1"
  if [[ "${status}" == 0 ]]; then
    echo verified
  elif [[ "${status}" == "${RECORD_DOES_NOT_VERIFY_STATUS}" ]]; then
    echo "does not verify"
  else
    echo "could not verify"
  fi
}

cmd_check() {
  refuse_untrusted_event
  [[ -z "${ARTIFACT_NAME:-}" ]] || check_artifact_name "${ARTIFACT_NAME}"
  require_retention_days
  cli_path > /dev/null
}

cmd_run() {
  local given="$1"
  local out="${given}"
  [[ -n "${given}" ]] || die "The records directory is empty. Pass the records-directory output of the deploy or record-iac action."
  # A relative path starts with ./, so no command reads it as an option.
  [[ "${out}" == /* ]] || out="./${out}"
  [[ -d "${out}" ]] || die "The records directory '${given}' does not exist. Pass the records-directory output of the deploy or record-iac action."
  require_environment_name "${ENVIRONMENT:-}"
  set_operator_trust_file
  # The run statement, which the server signs when a run ends, when the step
  # gives one. The CLI checks each unit's record against it.
  local statement statement_args=()
  if [[ -n "${RUN_STATEMENT:-}" ]]; then
    statement="$(absolute_file_path run-statement "${RUN_STATEMENT}")" || exit 1
    statement_args=(--statement="${statement}")
  fi
  local default_artifact="iltero-record-bundles-${ENVIRONMENT}"
  # Each environment and stack has its own work folder, and with UNIT each
  # unit has its own, so their reports stay apart. The action empties the
  # folder first, so a report left by an earlier step is never taken for one
  # this step wrote.
  local temp stack work_root
  temp="$(runner_temp)" || exit 1
  stack="$(stack_work_folder_name)" || die "The action could not name the stack's work folder."
  work_root="${temp}/iltero-verify/${ENVIRONMENT}/${stack}"
  local bundled_units="*"
  if [[ -n "${UNIT:-}" ]]; then
    check_unit_name "${UNIT}"
    default_artifact+="-${UNIT}"
    work_root="${temp}/iltero-verify-unit/${ENVIRONMENT}/${stack}/${UNIT}"
    bundled_units="${UNIT}"
  fi
  rm -rf "${work_root}"
  local artifact
  artifact="$(artifact_name "${ARTIFACT_NAME:-}" "${default_artifact}")"
  local report
  report="$(report_enabled)"
  local units="${work_root}/units.tsv"
  local reports="${work_root}/reports"
  mkdir -p "${work_root}"
  # The units are checked before any output is written, so the upload steps
  # run only when the units are known.
  list_checked_units "${units}"
  if [[ -n "${UNIT:-}" ]]; then
    local unit_directory
    unit_directory="$(unit_dir "${UNIT}" "${units}")"
    printf '%s\t%s\n' "${UNIT}" "${unit_directory}" > "${units}"
  fi
  # Absolute, because the upload step resolves paths from the repository root.
  out="$(cd "${out}" && pwd -P)"
  # The upload takes only the bundles of the units this step checks.
  write_output bundles-path "${out}/units/${bundled_units}/car-*/"
  write_output artifact-name "${artifact}"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi

  local summary="${work_root}/summary.md" details="${work_root}/details.md"
  {
    echo "## Iltero record bundles: $(markdown_escape "${ENVIRONMENT}")"
    echo
    echo "| Unit | Build | Verify |"
    echo "| --- | --- | --- |"
  } > "${summary}"
  : > "${details}"

  local name work build built verify verify_ran status first_status=0 bundles
  while IFS=$'\t' read -r name _; do
    work="${work_root}/units/${name}"
    # Each unit starts with an empty work directory, so no earlier output shows.
    rm -rf "${work}"
    mkdir -p "${work}"
    echo "::group::${name}"
    build=0
    verify="not run"
    verify_ran=false
    run_cli_logged "${work}/build.txt" record build --out="${out}" --unit="${name}" || build=$?
    if [[ "${build}" -eq 0 ]]; then
      shopt -s nullglob
      bundles=("${out}/units/${name}"/car-*/)
      shopt -u nullglob
      if [[ "${#bundles[@]}" -ne 1 ]]; then
        echo "::error::Expected one record bundle for unit '${name}', found ${#bundles[@]}."
        verify="bundle not found"
        [[ "${#bundles[@]}" -eq 0 ]] || verify="${#bundles[@]} bundles found, expected 1"
        [[ "${first_status}" -ne 0 ]] || first_status=1
      else
        status=0
        run_cli_logged "${work}/verify.txt" record verify "${bundles[0]}" ${statement_args[@]+"${statement_args[@]}"} \
          || status=$?
        [[ "${status}" -eq 0 || "${first_status}" -ne 0 ]] || first_status="${status}"
        verify="$(verify_result "${status}")"
        verify_ran=true
      fi
    else
      [[ "${first_status}" -ne 0 ]] || first_status="${build}"
    fi
    echo "::endgroup::"
    built="built"
    [[ "${build}" -eq 0 ]] || built="build failed"
    echo "| ${name} | ${built} | ${verify} |" >> "${summary}"
    local step
    for step in build verify; do
      [[ -f "${work}/${step}.txt" ]] || continue
      append_details_block "${details}" "${name}: ${step}" "${work}/${step}.txt"
    done
    if [[ "${report}" == true && "${verify_ran}" == true ]]; then
      write_report "${name}" "${bundles[0]}" "${reports}" "${details}" "${work}/report.txt" \
        ${statement_args[@]+"${statement_args[@]}"} || [[ "${first_status}" -ne 0 ]] || first_status=1
    fi
  done < "${units}"

  {
    cat "${summary}"
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  [[ "${first_status}" -eq 0 ]] \
    || exit_with_error "${first_status}" "One or more records failed to build, verify or report. See the job summary."
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    run) [[ $# -eq 1 ]] || die "Usage: iac/verify.sh run RECORDS_DIRECTORY"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check | run RECORDS_DIRECTORY" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
