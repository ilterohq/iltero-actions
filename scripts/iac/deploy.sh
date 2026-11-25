#!/bin/bash
#
# Deploys every unit of a stack.
#
# Usage:
#   iac/deploy.sh check            Refuse untrusted and pull request events; check that setup ran.
#   iac/deploy.sh run ENVIRONMENT  Deploy every unit; write the job summary.
#
# Run from the project's directory. In a project linked to the server,
# the plan stage's check opens the run on the server for the pipeline run and
# environment, each later stage joins it, and the deploy sends each stage's
# record. A project not linked to the server deploys locally: no run, no
# upload and no pre-deploy stage.
#
# In a linked project, the deploy first runs iltero scanners install, which
# puts the scanners the CLI pins in the scanner folder, inside the tools
# folder. A stage runs them when the run's settings require them.
#
# For each unit, in the order `iltero units list` prints:
#   1. the tool's init, with a registry token when REGISTRY_HOST is set;
#   2. iltero state check, which refuses a unit that keeps its state in its
#      working directory;
#   3. the tool's plan, saved, and its JSON;
#   4. iltero iac check --stage plan;
#   5. the tool's plan again, as JSON, then iltero iac check --stage
#      pre_deploy with it (linked projects only, when the unit's record
#      requires the stage);
#   6. the tool's apply of the saved plan;
#   7. the state after the apply, as JSON;
#   8. iltero iac check --stage post_deploy, also after a failed apply.
# The deploy stops at the first step that fails, and exits with its code.
#
# When every unit deployed, the deploy reads back twice each unit whose record
# requires the post-verify stage, with the tool's reading of the deployed
# resources, then runs
#   9. iltero iac check --stage post_verify, from the two readings and the
#      state file that the post-deploy stage checked.
# The deploy takes every unit's first reading before any second reading, so
# the stack waits about one interval in all, not one interval per unit. A unit
# that fails post-verify does not stop the others.
# When WRITE_REPORT is true, the CLI also writes a report of each unit's record.
#
# Environment:
#   TOOL            The IaC tool the stack uses: one of SUPPORTED_TOOLS in lib/tool.sh.
#   REGISTRY_HOST   The private module registry's host name. Empty: no registry token.
#   WRITE_REPORT    true or false. True: write a report of each unit's record.
#   STORE_RECORDS   true or false. True: keep each stage's record in the run's artifact store.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-credentials.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/tool.sh"

# The shortest time between a unit's two readings, which the deploy gives the
# CLI. The deploy waits one second more, because the shell's clock and the
# tool's timestamps count whole seconds.
readonly READING_INTERVAL_SECONDS=60
# Terraform dates a plan to the second, and the CLI refuses a new plan that is
# not newer than the checked plan. When the first plan finished in the current
# second, the deploy waits this long before it plans again.
readonly REPLAN_WAIT_SECONDS=1

cmd_check() {
  refuse_untrusted_event
  require_deploy_event
  [[ -z "${ARTIFACT_NAME:-}" ]] || check_artifact_name "${ARTIFACT_NAME}"
  require_retention_days
  [[ -z "${REGISTRY_HOST:-}" ]] || check_registry_host "${REGISTRY_HOST}"
  cli_path > /dev/null
}

# Stops unless the registry is used only by a linked project. In a linked
# project, the CLI opens or joins the run on the server at each stage, so the
# job must be able to request its identity token.
require_project_permissions() {
  local linked="$1"
  [[ -z "${REGISTRY_HOST:-}" ]] || require_linked_for_registry "${linked}"
  [[ "${linked}" == false ]] || require_id_token
}

# Fills TOOL_ENVIRONMENT_PAIRS with the cloud's credentials and the tool's
# own input variables from the job's environment.
pass_cloud_credentials() {
  local name names
  names="$(tool_input_variable_names)" || return 1
  TOOL_ENVIRONMENT_PAIRS=()
  for name in "${CLOUD_CREDENTIAL_ENV[@]}" ${names}; do
    [[ -z "${!name+set}" ]] || TOOL_ENVIRONMENT_PAIRS+=("${name}=${!name}")
  done
}

# Deploys one unit. Sets UNIT_RESULTS to its summary row cells. Returns the
# code of the first step that failed.
deploy_unit() {
  local name="$1"
  local dir="$2"
  local work="$3"
  local environment="$4"
  local linked="$5"
  local out="$6"
  # A linked project's run is found by its stack and environment, at every stage.
  local run_args=(--unit="${name}" --out="${out}" --environment="${environment}" ${SERVER_OPTIONS[@]+"${SERVER_OPTIONS[@]}"})
  local saved_plan="${work}/${TOOL_SAVED_PLAN_FILE}"
  local plan_files=(--plan="${work}/plan.json" --saved-plan="${saved_plan}")
  UNIT_RESULTS=("not run" "not run" "not run" "not run")
  local tool_failed="${TOOL_DISPLAY_NAME} failed"

  local status=0
  pause_commands
  tool_check_environment_settings "${dir}" "${environment}" 2>&1 || status=$?
  resume_commands
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="not set up for this environment"
    echo "::error::Unit '${name}' is not set up for environment '${environment}'. See the log."
    return "${status}"
  fi

  # A fresh registry token for each init: it lives only a few minutes.
  local token_env=()
  if [[ -n "${REGISTRY_HOST:-}" ]]; then
    mint_registry_token "${REGISTRY_HOST}" || {
      UNIT_RESULTS[0]="could not get registry token"
      return 1
    }
    token_env=("${REGISTRY_TOKEN_ENV}")
    REGISTRY_TOKEN_ENV=""
  fi
  pause_commands
  tool_deploy_init "${work}" "${dir}" "${environment}" ${token_env[@]+"${token_env[@]}"} 2>&1 || status=$?
  resume_commands
  token_env=()
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="${tool_failed}"
    echo "::error::${TOOL_DISPLAY_NAME} could not initialize unit '${name}'."
    return "${status}"
  fi

  # Runs before the plan, so no provider or data source of the unit runs until
  # the check passes.
  # The CLI finds the unit's tool data through the adapter's variables, one
  # NAME=VALUE pair per line.
  local state_check_env
  state_check_env="$(tool_state_check_environment "${work}")" || return 1
  (
    while IFS= read -r pair; do
      [[ -z "${pair}" ]] || export "${pair?}"
    done <<< "${state_check_env}"
    state_check "${dir}" "${work}"
  ) || status=$?
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="state check failed"
    return "${status}"
  fi

  pause_commands
  tool_deploy_plan "${work}" "${dir}" "${environment}" 2>&1 || status=$?
  resume_commands
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="${tool_failed}"
    echo "::error::${TOOL_DISPLAY_NAME} could not plan unit '${name}'."
    return "${status}"
  fi
  local planned_at
  planned_at="$(date +%s)" || return 1
  # The saved plan and its JSON, which the CLI checks, are fingerprinted
  # together, so the apply can confirm that neither changed after the check.
  local checked_plan
  if ! checked_plan="$(plan_digests "${work}")"; then
    UNIT_RESULTS[0]="plan unreadable"
    echo "::error::The saved plan of unit '${name}' could not be read."
    return 1
  fi

  check_stage "${work}" plan "${plan_files[@]}" "${run_args[@]}" || status=$?
  UNIT_RESULTS[0]="$(check_result "${status}")"
  [[ "${status}" -eq 0 ]] || return "${status}"

  # Pre-deploy checks facts only the server holds, so it runs only in a
  # linked project, and only when the unit's record requires it.
  if [[ "${linked}" == true ]]; then
    local required
    required="$(record_requires_stage "${work}" "${out}" "${name}" pre_deploy)" || status=$?
    if [[ "${status}" -ne 0 ]]; then
      UNIT_RESULTS[1]="$(record_scope_failure "${status}")"
      return "${status}"
    fi
    if [[ "${required}" == true ]]; then
      # When the server says a later job applies the plan, the CLI compares
      # a new plan, made just before the apply, with the checked one. In a
      # run that plans and applies in one job, it sets the new plan aside.
      # The deploy cannot tell which the server says, so it always plans
      # again. It still applies only the saved plan.
      [[ "$(date +%s)" -gt "${planned_at}" ]] || sleep "${REPLAN_WAIT_SECONDS}"
      pause_commands
      tool_replan "${work}" "${dir}" "${work}/replan.json" 2>&1 || status=$?
      resume_commands
      if [[ "${status}" -ne 0 ]]; then
        UNIT_RESULTS[1]="${tool_failed}"
        echo "::error::${TOOL_DISPLAY_NAME} could not plan unit '${name}' again before the pre-deploy check."
        return "${status}"
      fi
      # Pass the plan stage's files, so the CLI can check they are the ones
      # the plan stage checked.
      check_stage "${work}" pre_deploy "${plan_files[@]}" --replan="${work}/replan.json" "${run_args[@]}" \
        || status=$?
      UNIT_RESULTS[1]="$(check_result "${status}")"
      [[ "${status}" -eq 0 ]] || return "${status}"
    else
      UNIT_RESULTS[1]="not required"
    fi
  else
    UNIT_RESULTS[1]="$(local_pre_deploy_result "${work}" "${out}" "${name}")" || status=$?
    if [[ "${status}" -ne 0 ]]; then
      if [[ "${UNIT_RESULTS[1]}" != "${PRE_DEPLOY_CANNOT_RUN_RESULT}" ]]; then
        UNIT_RESULTS[1]="$(record_scope_failure "${status}")"
        [[ -f "${out}/units/${name}/car.json" ]] || UNIT_RESULTS[1]="no record"
      fi
      return "${status}"
    fi
  fi

  # Only the plan that was checked is applied.
  local plan_to_apply
  if ! plan_to_apply="$(plan_digests "${work}")"; then
    UNIT_RESULTS[2]="plan unreadable"
    echo "::error::The saved plan of unit '${name}' could not be read, so the unit was not applied."
    return 1
  fi
  if [[ "${plan_to_apply}" != "${checked_plan}" ]]; then
    UNIT_RESULTS[2]="plan changed"
    echo "::error::The saved plan of unit '${name}' changed after it was checked, so the unit was not applied."
    return 1
  fi

  local apply_status=0 show_status=0
  pause_commands
  tool_apply "${work}" "${dir}" 2>&1 || apply_status=$?
  UNIT_RESULTS[2]="applied"
  [[ "${apply_status}" -eq 0 ]] || UNIT_RESULTS[2]="apply failed"
  tool_read_state "${work}" "${dir}" 2>&1 || show_status=$?
  resume_commands

  # The apply is recorded also when the tool could not read the state after
  # it: the record then holds the apply log alone.
  local state_args=(--state="${work}/state.json")
  if [[ "${show_status}" -ne 0 ]]; then
    echo "::error::${TOOL_DISPLAY_NAME} could not read the state of unit '${name}' after the apply."
    state_args=(--state-unreadable)
  fi

  status=0
  check_stage "${work}" post_deploy "${plan_files[@]}" --apply-log="${work}/${TOOL_APPLY_LOG_FILE}" \
    "${state_args[@]}" "${run_args[@]}" || status=$?
  UNIT_RESULTS[3]="$(post_deploy_result "${status}" "${show_status}")"
  # The apply's own failure comes first, then the CLI's code.
  [[ "${apply_status}" -eq 0 ]] || return "${apply_status}"
  return "${status}"
}

# Prints the SHA-256 digest of FILE.
file_digest() {
  "$(tools_dir)/venv/bin/python" -I -c '
import hashlib, sys
with open(sys.argv[1], "rb") as data:
    print(hashlib.sha256(data.read()).hexdigest())
' "$1"
}

# Prints the SHA-256 digests of the saved plan in WORK and of its JSON, on one
# line. Fails unless both files can be read.
plan_digests() {
  local work="$1"
  local saved json
  saved="$(file_digest "${work}/${TOOL_SAVED_PLAN_FILE}")" && [[ "${saved}" =~ ${SHA256_PATTERN} ]] || return 1
  json="$(file_digest "${work}/plan.json")" && [[ "${json}" =~ ${SHA256_PATTERN} ]] || return 1
  echo "${saved} ${json}"
}

# Runs the post-verify stage for each deployed unit whose record requires it.
# The units are UNIT_NAMES and UNIT_DIRS. Sets POST_VERIFY_RESULTS to each
# unit's summary cell. A failed unit does not stop the others. Returns the
# code of the first step that failed.
post_verify_units() {
  local work_root="$1"
  local out="$2"
  local environment="$3"
  local readings="${work_root}/readings"
  local i name work required in_scope=() first_done=() status=0 first_status=0 wait_seconds
  POST_VERIFY_RESULTS=()
  for i in "${!UNIT_NAMES[@]}"; do
    POST_VERIFY_RESULTS[i]="not required"
    status=0
    required="$(record_requires_stage "${work_root}/units/${UNIT_NAMES[i]}" "${out}" "${UNIT_NAMES[i]}" post_verify)" \
      || status=$?
    if [[ "${status}" -ne 0 ]]; then
      POST_VERIFY_RESULTS[i]="$(record_scope_failure "${status}")"
      [[ "${first_status}" -ne 0 ]] || first_status="${status}"
      continue
    fi
    [[ "${required}" == true ]] || continue
    POST_VERIFY_RESULTS[i]="not run"
    in_scope+=("${i}")
  done

  for i in ${in_scope[@]+"${in_scope[@]}"}; do
    name="${UNIT_NAMES[i]}"
    mkdir -p "${readings}/${name}" || return 1
    status=0
    echo "::group::${name}: first reading"
    pause_commands
    tool_take_reading "${work_root}/units/${name}" "${UNIT_DIRS[i]}" "${readings}/${name}/first.json" 2>&1 || status=$?
    resume_commands
    echo "::endgroup::"
    first_done[i]="${SECONDS}"
    if [[ "${status}" -ne 0 ]]; then
      POST_VERIFY_RESULTS[i]="${TOOL_DISPLAY_NAME} failed"
      echo "::error::${TOOL_DISPLAY_NAME} could not read the deployed resources of unit '${name}'."
      [[ "${first_status}" -ne 0 ]] || first_status="${status}"
    fi
  done

  for i in ${in_scope[@]+"${in_scope[@]}"}; do
    # Skips a unit whose first reading failed.
    [[ "${POST_VERIFY_RESULTS[i]}" == "not run" ]] || continue
    name="${UNIT_NAMES[i]}"
    work="${work_root}/units/${name}"
    wait_seconds=$((first_done[i] + READING_INTERVAL_SECONDS + 1 - SECONDS))
    if [[ "${wait_seconds}" -gt 0 ]]; then
      echo "Waiting ${wait_seconds} seconds before the second reading of unit '${name}'."
      sleep "${wait_seconds}"
    fi
    status=0
    echo "::group::${name}: second reading and post-verify"
    pause_commands
    tool_take_reading "${work}" "${UNIT_DIRS[i]}" "${readings}/${name}/second.json" 2>&1 || status=$?
    resume_commands
    if [[ "${status}" -ne 0 ]]; then
      POST_VERIFY_RESULTS[i]="${TOOL_DISPLAY_NAME} failed"
      echo "::error::${TOOL_DISPLAY_NAME} could not read the deployed resources of unit '${name}'."
    else
      local run_args=(--unit="${name}" --out="${out}" --environment="${environment}" ${SERVER_OPTIONS[@]+"${SERVER_OPTIONS[@]}"})
      # Post-verify also gets the state file that the post-deploy stage checked.
      # The CLI confirms it is the same file, and reads it only for the checks
      # that the plan stage left until after the apply.
      check_stage "${work}" post_verify --refresh-plan="${readings}/${name}/first.json" \
        --refresh-plan="${readings}/${name}/second.json" --state="${work}/state.json" \
        --minimum-interval-seconds="${READING_INTERVAL_SECONDS}" "${run_args[@]}" || status=$?
      POST_VERIFY_RESULTS[i]="$(check_result "${status}")"
    fi
    echo "::endgroup::"
    [[ "${status}" -eq 0 || "${first_status}" -ne 0 ]] || first_status="${status}"
  done
  return "${first_status}"
}

cmd_run() {
  local environment="$1"
  local linked report
  require_environment_name "${environment}"
  set_operator_trust_file
  report="$(report_enabled)"
  linked="$(project_linked)"
  require_project_permissions "${linked}"
  set_server_options "${linked}"
  pass_cloud_credentials || die "The action could not read the tool's input variables."
  readonly TOOL_ENVIRONMENT_PAIRS
  # Each environment and stack has its own work folder, so two deploys in one
  # job keep their records apart. The action empties the folder first, so a
  # record left by an earlier deploy is never taken for one this deploy wrote.
  local temp stack work_root
  temp="$(runner_temp)" || exit 1
  stack="$(stack_work_folder_name)" || die "The action could not name the stack's work folder."
  work_root="${temp}/iltero-deploy/${environment}/${stack}"
  rm -rf "${work_root}"
  local out="${work_root}/out" artifact
  artifact="$(artifact_name "${ARTIFACT_NAME:-}" "iltero-deploy-${environment}")"
  local units="${work_root}/units.tsv"
  local reports="${work_root}/reports"
  mkdir -p "${out}" "${work_root}/readings"
  # The action checks the unit list before it writes any output. When the
  # list fails its checks, the step writes no output, and the upload steps
  # do not run.
  list_checked_units "${units}"
  # Install the scanners before the IaC tool first runs, so that the check on
  # the tools folder also covers the scanners from then on.
  [[ "${linked}" == false ]] || install_scanners "${work_root}/scanners-install.txt"
  write_output records-directory "${out}"
  write_output artifact-name "${artifact}"
  write_output readings-directory "${work_root}/readings"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi

  local summary="${work_root}/summary.md" details="${work_root}/details.md"
  {
    echo "## Iltero deploy: $(markdown_escape "${environment}")"
    echo
    echo "| Unit | Plan | Pre-deploy | Apply | Post-deploy | Post-verify |"
    echo "| --- | --- | --- | --- | --- | --- |"
  } > "${summary}"
  : > "${details}"
  trust_paths "${out}" "${units}" "${summary}" "${details}"

  local name dir work status=0 failed_unit="" verify_failed=false stage report_missing=0 i rows=()
  UNIT_NAMES=() UNIT_DIRS=() POST_VERIFY_RESULTS=()
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    mkdir -p "${work}"
    echo "::group::${name}"
    deploy_unit "${name}" "${dir}" "${work}" "${environment}" "${linked}" "${out}" || status=$?
    echo "::endgroup::"
    UNIT_NAMES+=("${name}")
    UNIT_DIRS+=("${dir}")
    rows+=("| ${name} | ${UNIT_RESULTS[0]} | ${UNIT_RESULTS[1]} | ${UNIT_RESULTS[2]} | ${UNIT_RESULTS[3]} |")
    if [[ "${status}" -ne 0 ]]; then
      failed_unit="${name}"
      break
    fi
  done < "${units}"
  if [[ -z "${failed_unit}" ]]; then
    post_verify_units "${work_root}" "${out}" "${environment}" || { status=$?; verify_failed=true; }
  fi

  for i in "${!UNIT_NAMES[@]}"; do
    name="${UNIT_NAMES[i]}"
    work="${work_root}/units/${name}"
    # The post-verify stage runs only when every unit deployed.
    if [[ -n "${failed_unit}" ]]; then
      echo "${rows[i]} not run |" >> "${summary}"
    else
      echo "${rows[i]} ${POST_VERIFY_RESULTS[i]:--} |" >> "${summary}"
    fi
    for stage in state-check plan in-scope-pre_deploy pre_deploy post_deploy in-scope-post_verify post_verify; do
      [[ -f "${work}/${stage}.txt" ]] || continue
      append_details_block "${details}" "${name}: $(details_title "${stage}")" "${work}/${stage}.txt"
    done
    if [[ "${report}" == true && -f "${out}/units/${name}/car.json" ]]; then
      write_report "${name}" "${out}/units/${name}" "${reports}" "${details}" "${work}/report.txt" || report_missing=1
    fi
  done
  # The summary lists every unit of the stack: those after a failed unit were
  # not deployed.
  local reached=" ${UNIT_NAMES[*]} "
  while IFS=$'\t' read -r name _; do
    [[ "${reached}" == *" ${name} "* ]] || echo "| ${name} | not run | not run | not run | not run | not run |" >> "${summary}"
  done < "${units}"

  {
    cat "${summary}"
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  if [[ -n "${failed_unit}" ]]; then
    echo "::error::The deploy stopped at unit '${failed_unit}'. Later units were not deployed. See the job summary."
    exit "${status}"
  fi
  if [[ "${verify_failed}" == true ]]; then
    echo "::error::The post-verify stage failed for one or more units. See the job summary."
    exit "${status}"
  fi
  [[ "${report_missing}" -eq 0 ]] || die "The CLI wrote no report for one or more units. See the log."
}

main() {
  local command="${1:-}"
  shift || true
  load_tool "${TOOL:-}"
  case "${command}" in
    check) cmd_check ;;
    run) [[ $# -eq 1 ]] || die "Usage: iac/deploy.sh run ENVIRONMENT"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check | run ENVIRONMENT" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # A stop signal, such as the one stop_step sends, ends the step as failed,
  # after any exit trap.
  trap 'exit 143' TERM
  main "$@"
fi
