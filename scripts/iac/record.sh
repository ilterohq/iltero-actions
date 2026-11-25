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
# Run from the project's directory. In a project linked to the server,
# the plan stage's check opens the run on the server for the pipeline run and
# environment, each later stage joins it, and the action sends each stage's
# record. A project not linked to the server records locally: no run, no
# upload, and no pre-deploy stage. On a pull request event, plan runs as a
# local preview, linked or not. In a linked project, the plan stage runs
# iltero scanners install after the state check and before its check, which
# puts the scanners the CLI pins in the scanner folder, inside the tools
# folder. The stage runs them when the run's settings require them.
#
# The CLI keeps each unit's record in RECORDS_DIRECTORY. Pre-deploy reads the
# plan stage's record from it. When pre_deploy runs in a different job from
# plan, that job needs the plan job's records directory. That job also gives
# SAVED_PLAN, the saved plan file it will apply, PLAN, the plan rendered from
# it with `terraform show -json`, and REPLAN, a new plan made just before the
# apply.
#
# Environment:
#   ENVIRONMENT                The environment the change deploys to.
#   UNIT                       The unit's name, as `iltero units list` prints it.
#   PLAN                       The saved plan as JSON, from `terraform show -json`.
#   SAVED_PLAN                 The saved plan file, from `terraform plan -out`.
#   REPLAN                     Pre-deploy only. A new plan as JSON, made in the job that applies, just before the
#                              apply. It is never applied.
#   SCAN_REPORTS               Plan only. Scan reports of the plan as JSON (PLAN), one per line: the scanner's
#                              name, a space, the report's path.
#   APPLY_LOG                  The output of `terraform apply -json`.
#   STATE                      The state after the apply, from `terraform show -json`. Post-verify
#                              takes the same file as post-deploy.
#   STATE_UNREADABLE           true or false. True: Terraform could not read the state after the apply.
#   REFRESH_ONLY_PLANS         Two refresh-only plans as JSON, one path per line, in the order
#                              they were taken: two readings of the deployed resources.
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
# The scanners whose reports of a plan the CLI reads.
readonly SCANNERS=(checkov trivy)

# Stops unless record-iac records STAGE on the job's event.
check_stage_input() {
  check_stage_for_event record-iac "the plan" "$1" "${STAGES[@]}"
}

cmd_check() {
  local stage="$1"
  check_stage_input "${stage}"
  [[ -z "${ARTIFACT_NAME:-}" ]] || check_artifact_name "${ARTIFACT_NAME}"
  require_retention_days
  cli_path > /dev/null
}

# Stops unless the input INPUT, whose value is PATH_VALUE, names a file.
require_file() {
  local input="$1"
  local path_value="$2"
  [[ -n "${path_value}" ]] || die "The ${input} input is required for stage ${STAGE}."
  require_named_file "${input}" "${path_value}"
}

# The file inputs of record-iac, as VARIABLE:input, and the inputs each stage
# reads.
readonly RECORD_FILE_INPUTS=(PLAN:plan SAVED_PLAN:saved-plan REPLAN:replan SCAN_REPORTS:scan-reports APPLY_LOG:apply-log
  STATE:state REFRESH_ONLY_PLANS:refresh-only-plans)
readonly PLAN_STAGE_INPUTS="plan saved-plan scan-reports"
readonly PRE_DEPLOY_STAGE_INPUTS="plan saved-plan replan"
readonly POST_DEPLOY_STAGE_INPUTS="plan saved-plan apply-log state"
readonly POST_VERIFY_STAGE_INPUTS="refresh-only-plans state"

# Stops when the step gives a file input that STAGE does not read, so the
# step never seems to record a file it ignored.
refuse_unused_inputs() {
  local used pair variable input
  case "${STAGE}" in
    plan) used="${PLAN_STAGE_INPUTS}" ;;
    pre_deploy) used="${PRE_DEPLOY_STAGE_INPUTS}" ;;
    post_deploy) used="${POST_DEPLOY_STAGE_INPUTS}" ;;
    post_verify) used="${POST_VERIFY_STAGE_INPUTS}" ;;
    *) die "Unknown stage '${STAGE}'." ;;
  esac
  for pair in "${RECORD_FILE_INPUTS[@]}"; do
    variable="${pair%%:*}"
    input="${pair#*:}"
    [[ -z "${!variable:-}" || " ${used} " == *" ${input} "* ]] \
      || die "Stage ${STAGE} does not read the ${input} input. Remove it from this step."
  done
}

# Runs the CLI's check of STAGE for the unit. LINKED is true in a project
# linked to the server. Returns the CLI's exit code.
record_event() {
  local dir="$1"
  local work="$2"
  local linked="$3"
  shift 3
  local run_args=("$@")
  case "${STAGE}" in
    plan)
      require_file plan "${PLAN:-}"
      require_file saved-plan "${SAVED_PLAN:-}"
      add_scan_report_options "${SCAN_REPORTS:-}" "${SCANNERS[@]}"
      # The state check reads the job's own TF_DATA_DIR when it is set.
      local status=0
      state_check "${dir}" "${work}" || status=$?
      if [[ "${status}" -ne 0 ]]; then
        STATE_CHECK_FAILED=true
        return "${status}"
      fi
      [[ "${linked}" == false ]] || install_scanners "${work}/scanners-install.txt"
      check_stage "${work}" plan --plan="${PLAN}" --saved-plan="${SAVED_PLAN}" \
        ${SCAN_REPORT_OPTIONS[@]+"${SCAN_REPORT_OPTIONS[@]}"} "${run_args[@]}"
      ;;
    pre_deploy)
      # Optional: the plan rendered from the saved plan file the job will
      # apply, that file, and a new plan made just before the apply. A later
      # job that applies the plan gives all three.
      local plan_args=()
      if [[ -n "${PLAN:-}" ]]; then
        require_named_file plan "${PLAN}"
        plan_args+=(--plan="${PLAN}")
      fi
      if [[ -n "${SAVED_PLAN:-}" ]]; then
        require_named_file saved-plan "${SAVED_PLAN}"
        plan_args+=(--saved-plan="${SAVED_PLAN}")
      fi
      if [[ -n "${REPLAN:-}" ]]; then
        require_named_file replan "${REPLAN}"
        plan_args+=(--replan="${REPLAN}")
      fi
      check_stage "${work}" pre_deploy ${plan_args[@]+"${plan_args[@]}"} "${run_args[@]}"
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
        line="$(trim "${line}")"
        require_one_line refresh-only-plans "${line}"
        [[ -z "${line}" ]] || readings+=("${line}")
      done <<< "${REFRESH_ONLY_PLANS:-}"
      [[ "${#readings[@]}" -eq 2 ]] \
        || die "The refresh-only-plans input must name two refresh-only plans, one per line, in the order they were taken. It names ${#readings[@]}."
      require_file refresh-only-plans "${readings[0]}"
      require_file refresh-only-plans "${readings[1]}"
      # The CLI checks that this is the state post-deploy read, and reads it
      # only for the checks that the plan stage left until after the apply.
      # The action cannot tell whether the plan left any, so it always
      # requires the file.
      require_file state "${STATE:-}"
      check_stage "${work}" post_verify --refresh-plan="${readings[0]}" --refresh-plan="${readings[1]}" \
        --state="${STATE}" "${run_args[@]}"
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
  refuse_unused_inputs
  [[ -n "${UNIT:-}" ]] || die "The unit input is required."
  check_unit_name "${UNIT}"
  local artifact
  artifact="$(artifact_name "${ARTIFACT_NAME:-}" "iltero-records-${ENVIRONMENT}-${UNIT}")"
  local report linked=false
  report="$(report_enabled)"
  if ! is_pull_request_event; then
    linked="$(project_linked)"
    # The CLI opens or joins the run on the server with the job's identity token.
    [[ "${linked}" == false ]] || require_id_token
  fi
  set_server_options "${linked}"

  # Each environment and stack has its own work folder and default records
  # folder, so two stacks in one job keep their records and reports apart. Every
  # stage of one stack shares them, so a later stage reads the record of an
  # earlier stage.
  local temp stack
  temp="$(runner_temp)" || exit 1
  stack="$(stack_work_folder_name)" || die "The action could not name the stack's work folder."
  local work_root="${temp}/iltero-record-iac/${ENVIRONMENT}/${stack}"
  local units="${work_root}/units.tsv"
  local dir
  mkdir -p "${work_root}"
  list_checked_units "${units}"
  dir="$(unit_dir "${UNIT}" "${units}")"
  local out="${RECORDS_DIRECTORY:-${temp}/iltero-records/${ENVIRONMENT}/${stack}}"
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
  local run_args=(--unit="${UNIT}" --out="${out}" --environment="${ENVIRONMENT}" ${SERVER_OPTIONS[@]+"${SERVER_OPTIONS[@]}"})
  # A pull request's plan is a local preview, never recorded on the server.
  ! is_pull_request_event || run_args+=(--local)
  local status=0 result
  if [[ "${STAGE}" == pre_deploy ]]; then
    [[ -f "${out}/units/${UNIT}/car.json" ]] \
      || die "The records directory holds no record of unit '${UNIT}'. Run the plan stage first. In another job, download the plan job's records artifact and pass its directory as records-directory."
  fi
  if [[ "${STAGE}" == pre_deploy && "${linked}" == false ]]; then
    # Pre-deploy checks facts only the server holds, so it reads no file here.
    [[ -z "${PLAN:-}" && -z "${SAVED_PLAN:-}" && -z "${REPLAN:-}" ]] \
      || die "In a project not linked to the server, pre_deploy does not read the plan, saved-plan or replan input. Remove them from this step."
    result="$(local_pre_deploy_result "${work}" "${out}" "${UNIT}")" || status=$?
    [[ "${status}" -ne 0 ]] \
      || echo "::notice::A project not linked to the server does not run the pre-deploy stage, and this unit's record does not require it. Nothing was checked."
    [[ "${status}" -eq 0 || "${result}" == "${PRE_DEPLOY_CANNOT_RUN_RESULT}" ]] || result="$(record_scope_failure "${status}")"
  else
    STATE_CHECK_FAILED=false
    record_event "${dir}" "${work}" "${linked}" "${run_args[@]}" || status=$?
    if [[ "${STATE_CHECK_FAILED}" == true ]]; then
      result="state check failed"
    elif [[ "${STATE_UNREADABLE}" == true ]]; then
      result="$(post_deploy_result "${status}" 1)"
    else
      result="$(check_result "${status}")"
    fi
    if [[ "${status}" -eq 0 && "${linked}" == true && ("${STAGE}" == pre_deploy || "${STAGE}" == post_verify) ]]; then
      # The CLI also exits 0, and checks nothing, when the server says the
      # environment's policy leaves the stage out. Ask the CLI whether the
      # unit's record requires the stage, so the summary does not read
      # "passed" for a stage that checked nothing.
      local required
      required="$(record_requires_stage "${work}" "${out}" "${UNIT}" "${STAGE}")" || status=$?
      if [[ "${status}" -ne 0 ]]; then
        result="$(record_scope_failure "${status}")"
      elif [[ "${required}" == false ]]; then
        result="not required"
      fi
    fi
  fi

  local details="${work}/details.md" step report_missing=0
  : > "${details}"
  for step in state-check "${STAGE}" "in-scope-${STAGE}"; do
    [[ -f "${work}/${step}.txt" ]] || continue
    append_details_block "${details}" "${UNIT}: $(details_title "${step}")" "${work}/${step}.txt"
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
