#!/bin/bash
#
# Records one stage of one unit's change, inside the job that runs Terraform.
# The job runs Terraform itself; this script reads the files it wrote and runs
# the CLI's check of that stage. It runs no Terraform.
#
# Usage:
#   iac/record.sh check STAGE    Refuse untrusted events and pull request review events, and on
#                                pull_request events any stage but plan; check the stage's name
#                                and that setup ran.
#   iac/record.sh run STAGE      Run the CLI's check of STAGE for UNIT; write the job summary.
#
# Run from the stack's working directory. In a project linked to the server,
# the plan stage's check opens the run on the server for the pipeline run and
# environment, each later stage joins it, and the action sends each stage's
# record. A project with no platform section in .iltero/config.yml records
# locally: no run, no upload, and no pre-deploy stage. On a pull request
# event, plan runs as a local preview, linked or not.
#
# The CLI keeps each unit's record in RECORDS_DIRECTORY. Pre-deploy reads the
# plan stage's record from it. When pre_deploy runs in a different job from
# plan, that job needs the plan job's records directory.
#
# Environment:
#   ENVIRONMENT                The environment the change deploys to.
#   UNIT                       The unit's name, as `iltero units list` prints it.
#   PLAN                       The saved plan as JSON, from `terraform show -json`.
#   SAVED_PLAN                 The saved plan file, from `terraform plan -out`.
#   APPLY_LOG                  The output of `terraform apply -json`.
#   STATE                      The state after the apply, from `terraform show -json`.
#   STATE_UNREADABLE           true or false. True: Terraform could not read the state after the apply.
#   REFRESH_PLANS              Two readings of the deployed resources, one path per line, in the
#                              order they were taken. Each is a refresh-only plan as JSON.
#   RECORDS_DIRECTORY          Where the CLI keeps the records. Empty: a directory for the environment
#                              in RUNNER_TEMP.
#   ARTIFACT_NAME              The records artifact's name. Empty: iltero-records-<environment>-<unit>.
#   WRITE_REPORT               true or false. True: write a report of the unit's record.
#   STORE_RECORDS              true or false. True: keep the stage's record in the run's artifact store.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"

# The CLI's stages record-iac records.
readonly STAGES=(plan pre_deploy post_deploy post_verify)

# Stops unless record-iac records STAGE on the job's event.
check_stage_input() {
  check_stage_for_event record-iac "the plan" "$1" "${STAGES[@]}"
}

cmd_check() {
  local stage="$1"
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
      # The state check reads the job's own TF_DATA_DIR when it is set.
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
      # The apply is recorded also when Terraform could not read the state
      # after it: the record then holds the apply log alone.
      local state_args=()
      if [[ "${STATE_UNREADABLE}" == true ]]; then
        [[ -z "${STATE:-}" ]] || die "Give either the state input or state-unreadable: true, not both."
        state_args=(--state-unreadable)
      else
        require_file state "${STATE:-}"
        state_args=(--state="${STATE}")
      fi
      check_stage "${work}" post_deploy --plan="${PLAN}" --saved-plan="${SAVED_PLAN}" \
        --apply-log="${APPLY_LOG}" "${state_args[@]}" "${run_args[@]}"
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
  require_environment_name "${ENVIRONMENT:-}"
  require_true_or_false state-unreadable "${STATE_UNREADABLE:-}"
  [[ "${STATE_UNREADABLE}" == false || "${STAGE}" == post_deploy ]] \
    || die "The state-unreadable input applies only to the post_deploy stage."
  [[ -n "${UNIT:-}" ]] || die "The unit input is required."
  [[ "${UNIT}" =~ ${UNIT_NAME_PATTERN} ]] || die "Unit name '${UNIT}' does not follow the unit-name rule."
  local artifact
  artifact="$(artifact_name "${ARTIFACT_NAME:-}" "iltero-records-${ENVIRONMENT}-${UNIT}")"
  local report linked=false
  report="$(report_enabled)"
  if ! is_pull_request_event; then
    linked="$(project_linked)"
    # The CLI opens or joins the run on the server with the job's identity token.
    [[ "${linked}" == false ]] || require_id_token
  fi
  set_server_args "${linked}"

  # Each environment has its own work directory, so its reports stay apart.
  local work_root="${RUNNER_TEMP}/iltero-record-iac/${ENVIRONMENT}"
  local units="${work_root}/units.tsv"
  local dir
  mkdir -p "${work_root}"
  list_checked_units "${units}"
  dir="$(unit_dir "${UNIT}" "${units}")"
  local out="${RECORDS_DIRECTORY:-${RUNNER_TEMP}/iltero-records/${ENVIRONMENT}}"
  # A relative path starts with ./, so no command reads it as an option.
  [[ "${out}" == /* ]] || out="./${out}"
  local work="${work_root}/units/${UNIT}/${STAGE}"
  local reports="${work_root}/reports"
  rm -rf "${work}"
  mkdir -p "${out}" "${work}"
  # Absolute, because the upload step resolves paths from the repository root.
  out="$(cd "${out}" && pwd -P)"
  write_output records-directory "${out}"
  write_output artifact-name "${artifact}"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi

  # A linked project's run is found by its stack and environment, at every stage.
  local run_args=(--unit="${UNIT}" --out="${out}" --environment="${ENVIRONMENT}" ${SERVER_ARGS[@]+"${SERVER_ARGS[@]}"})
  # A pull request's plan is a local preview, never recorded on the server.
  ! is_pull_request_event || run_args+=(--local)
  local status=0 result
  if [[ "${STAGE}" == pre_deploy && "${linked}" == false ]]; then
    # Pre-deploy checks facts only the server holds.
    [[ -f "${out}/units/${UNIT}/car.json" ]] \
      || die "The records directory holds no record of unit '${UNIT}'. Run the plan stage first. In another job, download the plan job's records artifact and pass its directory as records-directory."
    echo "::notice::A project with no platform section does not run the pre-deploy stage. Nothing was checked."
    result="$(local_pre_deploy_result "${work}" "${out}" "${UNIT}")" || status=$?
    [[ "${status}" -eq 0 ]] || result="$(record_scope_failure "${status}")"
  else
    STATE_CHECK_FAILED=false
    record_event "${dir}" "${work}" "${run_args[@]}" || status=$?
    result="exit ${status}"
    [[ "${STATE_CHECK_FAILED}" == false ]] || result="state check exit ${status}"
    [[ "${STATE_UNREADABLE}" == false ]] || result+=", state not read"
  fi

  local details="${work}/details.md" step report_missing=0
  : > "${details}"
  for step in state-check "in-scope-${STAGE}" "${STAGE}"; do
    [[ -f "${work}/${step}.txt" ]] || continue
    append_details_block "${details}" "${UNIT}: ${step//_/-}" "${work}/${step}.txt"
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
    check) [[ $# -eq 1 ]] || die "Usage: iac/record.sh check STAGE"; cmd_check "$@" ;;
    run) [[ $# -eq 1 ]] || die "Usage: iac/record.sh run STAGE"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check STAGE | run STAGE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
