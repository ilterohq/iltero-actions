#!/bin/bash
#
# Records one stage of one unit's change, inside the job that runs Terraform.
# The job runs Terraform itself; this script reads the files it wrote and runs
# the CLI's check of that stage. It runs no Terraform.
#
# Usage:
#   record-iac.sh check STAGE    Refuse untrusted events and pull request review events, and on
#                                pull_request events any stage but plan; check the stage's name
#                                and that setup ran.
#   record-iac.sh run STAGE      Run the CLI's check of STAGE for UNIT; write the job summary.
#
# Run from the stack's working directory. In a project linked to Iltero
# Platform, the plan stage's check opens the run on the server for the pipeline
# run and environment, each later stage joins it, and the action sends each
# stage's record. A project
# with no platform section in .iltero/config.yml records locally: no run, no
# upload, and pre_deploy is not in scope. On a pull request event, plan runs as
# a local preview, linked or not.
#
# The CLI keeps each unit's record in RECORDS_DIRECTORY. Pre-deploy reads the
# plan stage's record from it, so a job that runs pre_deploy apart from plan
# needs the plan job's records directory.
#
# Environment:
#   ENVIRONMENT                The environment the change deploys to.
#   UNIT                       The unit's name, as `iltero units list` prints it.
#   PLAN                       The saved plan as JSON, from `terraform show -json`.
#   SAVED_PLAN                 The saved plan file, from `terraform plan -out`.
#   APPLY_LOG                  The output of `terraform apply -json`.
#   STATE                      The state after the apply, from `terraform show -json`.
#   REFRESH_PLANS              Two readings of the deployed resources, one path per line, in the
#                              order they were taken. Each is a refresh-only plan as JSON.
#   RECORDS_DIRECTORY          Where the CLI keeps the records. Empty: a folder in RUNNER_TEMP.
#   ARTIFACT_NAME              The records artifact's name. Empty: iltero-records-<unit>.
#   WRITE_REPORT               true or false. True: write a report of the unit's record.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"

# The CLI's stages record-iac records.
readonly STAGES=(plan pre_deploy post_deploy post_verify)

# Stops unless record-iac records STAGE on the job's event.
check_stage_input() {
  local stage="$1"
  [[ " ${STAGES[*]} " == *" ${stage} "* ]] \
    || die "The stage input must be one of: ${STAGES[*]}. It is '${stage}'."
  if is_pull_request_event; then
    [[ "${GITHUB_EVENT_NAME}" == pull_request ]] \
      || die "record-iac does not run on ${GITHUB_EVENT_NAME} events. Run it on pull_request events, where it checks the plan locally."
    [[ "${stage}" == plan ]] \
      || die "On pull request events, record-iac records only the plan stage, as a local preview."
  fi
}

cmd_check() {
  local stage="$1"
  refuse_untrusted_event
  check_stage_input "${stage}"
  [[ -z "${ARTIFACT_NAME:-}" ]] || check_artifact_name "${ARTIFACT_NAME}"
  cli_path > /dev/null
}

# Prints the directory of the unit named NAME, from the checked unit list in
# FILE. Stops when no unit has it.
unit_dir() {
  local name="$1"
  local file="$2"
  local listed dir
  while IFS=$'\t' read -r listed dir; do
    if [[ "${listed}" == "${name}" ]]; then
      echo "${dir}"
      return 0
    fi
  done < "${file}"
  die "The stack has no unit '${name}'. Use a name that 'iltero units list' prints."
}

# Stops unless the input INPUT, whose value is PATH_VALUE, names a file.
require_file() {
  local input="$1"
  local path_value="$2"
  [[ -n "${path_value}" ]] || die "The ${input} input is required for stage ${STAGE}."
  [[ -f "${path_value}" ]] || die "The ${input} input names no file: '${path_value}'."
}

# Runs the CLI's check of STAGE for the unit. Returns the CLI's exit code.
record_event() {
  local dir="$1"
  local work="$2"
  shift 2
  local run_args=("$@")
  case "${STAGE}" in
    plan)
      require_file plan "${PLAN:-}"
      require_file saved-plan "${SAVED_PLAN:-}"
      # The job's own Terraform data directory, from its TF_DATA_DIR if set.
      local status=0
      state_check "${dir}" "${work}" || status=$?
      if [[ "${status}" -ne 0 ]]; then
        STATE_CHECK_FAILED=true
        return "${status}"
      fi
      check_stage "${work}" plan --plan="${PLAN}" --saved-plan="${SAVED_PLAN}" "${run_args[@]}"
      ;;
    pre_deploy)
      check_stage "${work}" pre_deploy "${run_args[@]}"
      ;;
    post_deploy)
      require_file plan "${PLAN:-}"
      require_file saved-plan "${SAVED_PLAN:-}"
      require_file apply-log "${APPLY_LOG:-}"
      require_file state "${STATE:-}"
      check_stage "${work}" post_deploy --plan="${PLAN}" --saved-plan="${SAVED_PLAN}" \
        --apply-log="${APPLY_LOG}" --state="${STATE}" "${run_args[@]}"
      ;;
    post_verify)
      local readings=() line
      while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] || readings+=("${line}")
      done <<< "${REFRESH_PLANS:-}"
      [[ "${#readings[@]}" -eq 2 ]] \
        || die "The refresh-plans input must name two readings, one per line, in the order they were taken. It names ${#readings[@]}."
      require_file refresh-plans "${readings[0]}"
      require_file refresh-plans "${readings[1]}"
      check_stage "${work}" post_verify --refresh-plan="${readings[0]}" --refresh-plan="${readings[1]}" \
        "${run_args[@]}"
      ;;
    *) die "Unknown stage '${STAGE}'." ;;
  esac
}

cmd_run() {
  STAGE="$1"
  check_stage_input "${STAGE}"
  [[ -n "${ENVIRONMENT:-}" ]] || die "The environment input is required."
  [[ "${ENVIRONMENT}" != *[[:cntrl:]]* ]] || die "The environment input must be a single line."
  [[ -n "${UNIT:-}" ]] || die "The unit input is required."
  local report linked=false
  report="$(report_enabled)"
  if ! is_pull_request_event; then
    linked="$(project_linked)"
    # The CLI opens or joins the run on the server with the job's identity token.
    [[ "${linked}" == false ]] || require_id_token
  fi

  local work_root="${RUNNER_TEMP}/iltero-record-iac"
  local units="${work_root}/units.tsv"
  local dir
  mkdir -p "${work_root}"
  list_checked_units "${units}"
  dir="$(unit_dir "${UNIT}" "${units}")"
  local out="${RECORDS_DIRECTORY:-${RUNNER_TEMP}/iltero-records}"
  local work="${work_root}/units/${UNIT}/${STAGE}"
  local reports="${work_root}/reports"
  rm -rf "${work}"
  mkdir -p "${out}" "${work}"
  # Absolute, because the upload step resolves paths from the repository root.
  out="$(cd "${out}" && pwd -P)"
  write_output records-directory "${out}"
  write_output artifact-name "${ARTIFACT_NAME:-iltero-records-${UNIT}}"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi

  # A linked project's run is found by its stack and environment, at every stage.
  local run_args=(--unit="${UNIT}" --out="${out}" --environment="${ENVIRONMENT}")
  [[ "${linked}" == false ]] || run_args+=(--upload)
  # A pull request's plan is a local preview, never recorded on the server.
  ! is_pull_request_event || run_args+=(--local)
  local status=0 result
  if [[ "${STAGE}" == pre_deploy && "${linked}" == false ]]; then
    # Pre-deploy checks facts only Iltero Platform holds.
    echo "::notice::Pre-deploy is not in scope for a local record. Nothing was checked."
    result="not in scope"
  else
    STATE_CHECK_FAILED=false
    record_event "${dir}" "${work}" "${run_args[@]}" || status=$?
    result="exit ${status}"
    [[ "${STATE_CHECK_FAILED}" == false ]] || result="state check exit ${status}"
  fi

  local details="${work}/details.md" step report_missing=0
  : > "${details}"
  for step in state-check "${STAGE}"; do
    [[ -f "${work}/${step}.txt" ]] || continue
    details_block "${UNIT}: ${step//_/-}" "${work}/${step}.txt" >> "${details}"
  done
  if [[ "${report}" == true && -f "${out}/units/${UNIT}/car.json" ]]; then
    write_report "${UNIT}" "${out}/units/${UNIT}" "${reports}" "${details}" "${work}/report.txt" || report_missing=1
  fi
  {
    echo "## Iltero record: $(markdown_escape "${UNIT}"), ${STAGE//_/-}"
    echo
    echo "Environment: $(markdown_escape "${ENVIRONMENT}"). Result: ${result}."
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  [[ "${status}" -eq 0 ]] || exit "${status}"
  [[ "${report_missing}" -eq 0 ]] || die "The CLI wrote no report for unit '${UNIT}'. See the log."
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) [[ $# -eq 1 ]] || die "Usage: record-iac.sh check STAGE"; cmd_check "$@" ;;
    run) [[ $# -eq 1 ]] || die "Usage: record-iac.sh run STAGE"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check STAGE | run STAGE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
