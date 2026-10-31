#!/bin/bash
#
# Deploys every unit of a stack.
#
# Usage:
#   deploy.sh check                            Refuse untrusted and pull request events; check that setup ran.
#   deploy.sh run ENVIRONMENT                  Deploy every unit; write the job summary.
#
# Run from the stack's working directory. In a project linked to Iltero
# Platform, the plan stage's check opens the run on the server for the
# pipeline run and environment, each later stage joins it, and the deploy
# sends each stage's record. A
# project with no platform section in .iltero/config.yml deploys locally: no
# run, no upload and no pre-deploy stage.
#
# For each unit, in the order `iltero units list` prints:
#   1. terraform init, with a registry token when REGISTRY_HOST is set;
#   2. iltero state check, which refuses a unit that keeps its state in its
#      working directory;
#   3. terraform plan, saved, and its JSON;
#   4. iltero iac check --stage plan;
#   5. iltero iac check --stage pre_deploy (linked projects only);
#   6. terraform apply of the saved plan;
#   7. the state after the apply, as JSON;
#   8. iltero iac check --stage post_deploy, also after a failed apply.
# The deploy stops at the first step that fails, and exits with its code.
#
# When every unit deployed, the deploy reads back twice each unit whose record
# expects the post-verify stage, with a refresh-only plan, then runs
#   9. iltero iac check --stage post_verify, from the two readings.
# The deploy takes every unit's first reading before any second reading, so
# the stack waits about one interval in all, not one interval per unit. A unit
# that fails post-verify does not stop the others.
# When WRITE_REPORT is true, the CLI also writes a report of each unit's record.
#
# Environment:
#   REGISTRY_HOST   The private module registry's host name. Empty: no registry token.
#   WRITE_REPORT    true or false. True: write a report of each unit's record.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-credentials.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/terraform.sh"

# The shortest time between a unit's two readings, which the deploy gives the
# CLI. The deploy waits one second more, because the shell's clock and
# Terraform's timestamps count whole seconds.
readonly READING_INTERVAL_SECONDS=60
# How long a reading waits for the state lock.
readonly READING_LOCK_TIMEOUT=5m

cmd_check() {
  refuse_untrusted_event
  refuse_pull_request
  cli_path > /dev/null
  terraform_path > /dev/null
}

# Stops unless the registry is used only by a linked project. In a linked
# project, the CLI opens or joins the run on the server at each stage, so the
# job must be able to request its identity token.
check_mode() {
  local linked="$1"
  [[ -z "${REGISTRY_HOST:-}" ]] || require_linked_for_registry "${linked}"
  [[ "${linked}" == false ]] || require_id_token
}

# Runs Terraform with the cloud's credentials and TF_VAR_* values added to
# what run_terraform keeps. Takes run_terraform's arguments.
terraform_scrubbed() {
  local work="$1"
  shift
  local kept=() name
  for name in "${CLOUD_CREDENTIAL_ENV[@]}" $(compgen -e | grep '^TF_VAR_' || true); do
    [[ -z "${!name+set}" ]] || kept+=("${name}=${!name}")
  done
  run_terraform "${work}" ${kept[@]+"${kept[@]}"} "$@"
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
  local run_args=(--unit="${name}" --out="${out}" --environment="${environment}")
  [[ "${linked}" == false ]] || run_args+=(--upload)
  local plan_files=(--plan="${work}/plan.json" --saved-plan="${work}/tfplan")
  UNIT_RESULTS=("-" "-" "-" "-")

  local backend_config var_file
  backend_config="$(unit_backend_config "${dir}" "${environment}")"
  var_file="$(unit_var_file "${dir}" "${environment}")"
  local init_args=(-input=false -no-color -lockfile=readonly)
  [[ ! -f "${backend_config}" ]] || init_args+=(-backend-config="${backend_config}")
  local variable_args=()
  [[ ! -f "${var_file}" ]] || variable_args+=(-var-file="${var_file}")
  if declares_remote_state_switch "${dir}"; then
    # Set from a variables file, not -var: Terraform records a -var value in
    # the plan as a string. The file comes last, so it wins.
    echo "${REMOTE_STATE_SWITCH} = true" > "${work}/with-upstream.tfvars" || return 1
    variable_args+=(-var-file="${work}/with-upstream.tfvars")
  fi
  # The readings after the deploy use the same variables.
  local arg
  : > "${work}/variable-args"
  for arg in ${variable_args[@]+"${variable_args[@]}"}; do
    echo "${arg}" >> "${work}/variable-args"
  done
  local plan_args=(-input=false -no-color -out="${work}/tfplan" ${variable_args[@]+"${variable_args[@]}"})

  # A fresh registry token for each init: it lives only a few minutes.
  local token_env=() status=0
  if [[ -n "${REGISTRY_HOST:-}" ]]; then
    mint_registry_token "${REGISTRY_HOST}"
    token_env=("${REGISTRY_TOKEN_ENV}")
    REGISTRY_TOKEN_ENV=""
  fi
  pause_commands
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" ${token_env[@]+"${token_env[@]}"} -- init "${init_args[@]}"
  ) || status=$?
  resume_commands
  token_env=()
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="terraform failed"
    echo "::error::Terraform could not initialize unit '${name}'."
    return "${status}"
  fi

  # Runs before the plan, so Terraform runs none of the unit's code until the
  # check passes.
  TF_DATA_DIR="$(terraform_data_dir "${work}")" state_check "${dir}" "${work}" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="state check exit ${status}"
    return "${status}"
  fi

  pause_commands
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" -- plan "${plan_args[@]}" \
      && terraform_scrubbed "${work}" -- show -json "${work}/tfplan" > "${work}/plan.json"
  ) || status=$?
  resume_commands
  if [[ "${status}" -ne 0 ]]; then
    UNIT_RESULTS[0]="terraform failed"
    echo "::error::Terraform could not plan unit '${name}'."
    return "${status}"
  fi

  check_stage "${work}" plan "${plan_files[@]}" "${run_args[@]}" || status=$?
  UNIT_RESULTS[0]="exit ${status}"
  [[ "${status}" -eq 0 ]] || return "${status}"

  # Pre-deploy checks facts only Iltero Platform holds, so it runs only in a
  # linked project.
  if [[ "${linked}" == true ]]; then
    check_stage "${work}" pre_deploy "${run_args[@]}" || status=$?
    UNIT_RESULTS[1]="exit ${status}"
    [[ "${status}" -eq 0 ]] || return "${status}"
  else
    UNIT_RESULTS[1]="not in scope"
  fi

  local apply_status=0 show_status=0
  pause_commands
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" -- apply -input=false -json "${work}/tfplan" > "${work}/apply.ndjson"
  ) || apply_status=$?
  UNIT_RESULTS[2]="exit ${apply_status}"
  (cd "${dir}" && terraform_scrubbed "${work}" -- show -json > "${work}/state.json") || show_status=$?
  resume_commands

  if [[ "${show_status}" -ne 0 ]]; then
    echo "::error::Terraform could not read the state of unit '${name}' after the apply."
    UNIT_RESULTS[3]="no state"
    [[ "${apply_status}" -eq 0 ]] || return "${apply_status}"
    return 1
  fi

  status=0
  check_stage "${work}" post_deploy "${plan_files[@]}" --apply-log="${work}/apply.ndjson" \
    --state="${work}/state.json" "${run_args[@]}" || status=$?
  UNIT_RESULTS[3]="exit ${status}"
  [[ "${apply_status}" -eq 0 ]] || return "${apply_status}"
  return "${status}"
}

# Takes a reading of the deployed resources of the unit in DIR into FILE, as
# JSON: a refresh-only plan, saved in the unit's work folder WORK and never
# applied. Applying it would write what it read into the state, so drift would
# no longer show.
take_reading() {
  local dir="$1"
  local work="$2"
  local file="$3"
  local saved
  saved="${work}/reading-$(basename "${file%.json}").tfplan"
  local variable_args=() line status=0
  while IFS= read -r line; do
    variable_args+=("${line}")
  done < "${work}/variable-args"
  pause_commands
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" -- plan -input=false -no-color -refresh-only \
      -lock-timeout="${READING_LOCK_TIMEOUT}" -out="${saved}" ${variable_args[@]+"${variable_args[@]}"} \
      && terraform_scrubbed "${work}" -- show -json "${saved}" > "${file}"
  ) || status=$?
  resume_commands
  # A reading Terraform did not finish is not kept.
  [[ "${status}" -eq 0 ]] || rm -f "${file}"
  return "${status}"
}

# Runs the post-verify stage for each deployed unit whose record expects it.
# The units are UNIT_NAMES and UNIT_DIRS. Sets POST_VERIFY_RESULTS to each
# unit's summary cell. A failed unit does not stop the others. Returns the
# code of the first step that failed.
post_verify_units() {
  local work_root="$1"
  local out="$2"
  local environment="$3"
  local linked="$4"
  local readings="${work_root}/readings"
  local i name work expects in_scope=() first_done=() status=0 first_status=0 wait
  POST_VERIFY_RESULTS=()
  for i in "${!UNIT_NAMES[@]}"; do
    POST_VERIFY_RESULTS[i]="not in scope"
    if ! expects="$(record_expects_stage "${out}" "${UNIT_NAMES[i]}" post_verify)"; then
      POST_VERIFY_RESULTS[i]="record unreadable"
      [[ "${first_status}" -ne 0 ]] || first_status=1
      continue
    fi
    [[ "${expects}" == true ]] || continue
    POST_VERIFY_RESULTS[i]="not run"
    in_scope+=("${i}")
  done

  for i in ${in_scope[@]+"${in_scope[@]}"}; do
    name="${UNIT_NAMES[i]}"
    mkdir -p "${readings}/${name}" || return 1
    status=0
    echo "::group::${name}: first reading"
    take_reading "${UNIT_DIRS[i]}" "${work_root}/units/${name}" "${readings}/${name}/first.json" || status=$?
    echo "::endgroup::"
    first_done[i]="${SECONDS}"
    if [[ "${status}" -ne 0 ]]; then
      POST_VERIFY_RESULTS[i]="terraform failed"
      echo "::error::Terraform could not read back unit '${name}'."
      [[ "${first_status}" -ne 0 ]] || first_status="${status}"
    fi
  done

  for i in ${in_scope[@]+"${in_scope[@]}"}; do
    # Skips a unit whose first reading failed.
    [[ "${POST_VERIFY_RESULTS[i]}" == "not run" ]] || continue
    name="${UNIT_NAMES[i]}"
    work="${work_root}/units/${name}"
    wait=$((first_done[i] + READING_INTERVAL_SECONDS + 1 - SECONDS))
    if [[ "${wait}" -gt 0 ]]; then
      echo "Waiting ${wait} seconds before the second reading of unit '${name}'."
      sleep "${wait}"
    fi
    status=0
    echo "::group::${name}: second reading and post-verify"
    take_reading "${UNIT_DIRS[i]}" "${work}" "${readings}/${name}/second.json" || status=$?
    if [[ "${status}" -ne 0 ]]; then
      POST_VERIFY_RESULTS[i]="terraform failed"
      echo "::error::Terraform could not read back unit '${name}'."
    else
      local run_args=(--unit="${name}" --out="${out}" --environment="${environment}")
      [[ "${linked}" == false ]] || run_args+=(--upload)
      check_stage "${work}" post_verify --refresh-plan="${readings}/${name}/first.json" \
        --refresh-plan="${readings}/${name}/second.json" \
        --minimum-interval-seconds="${READING_INTERVAL_SECONDS}" "${run_args[@]}" || status=$?
      POST_VERIFY_RESULTS[i]="exit ${status}"
    fi
    echo "::endgroup::"
    [[ "${status}" -eq 0 || "${first_status}" -ne 0 ]] || first_status="${status}"
  done
  return "${first_status}"
}

cmd_run() {
  local environment="$1"
  local linked report
  require_environment_file_name "${environment}"
  report="$(report_enabled)"
  linked="$(project_linked)"
  check_mode "${linked}"
  local work_root="${RUNNER_TEMP}/iltero-deploy"
  local out="${work_root}/out"
  local units="${work_root}/units.tsv"
  local reports="${work_root}/reports"
  mkdir -p "${out}" "${work_root}/readings"
  write_output records-directory "${out}"
  write_output readings-directory "${work_root}/readings"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-directory "${reports}"
  fi

  list_checked_units "${units}"

  local summary="${work_root}/summary.md" details="${work_root}/details.md"
  {
    echo "## Iltero deploy: $(markdown_escape "${environment}")"
    echo
    echo "| Unit | Plan | Pre-deploy | Apply | Post-deploy | Post-verify |"
    echo "| --- | --- | --- | --- | --- | --- |"
  } > "${summary}"
  : > "${details}"

  local name dir work status=0 failed_unit="" verify_failed=false stage report_missing=0 i rows=()
  UNIT_NAMES=() UNIT_DIRS=() POST_VERIFY_RESULTS=()
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    rm -rf "${work}" "${work_root}/readings/${name}"
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
    post_verify_units "${work_root}" "${out}" "${environment}" "${linked}" || { status=$?; verify_failed=true; }
  fi

  for i in "${!UNIT_NAMES[@]}"; do
    name="${UNIT_NAMES[i]}"
    work="${work_root}/units/${name}"
    echo "${rows[i]} ${POST_VERIFY_RESULTS[i]:--} |" >> "${summary}"
    for stage in state-check plan pre_deploy post_deploy post_verify; do
      [[ -f "${work}/${stage}.txt" ]] || continue
      details_block "${name}: ${stage//_/-}" "${work}/${stage}.txt" >> "${details}"
    done
    if [[ "${report}" == true && -f "${out}/units/${name}/car.json" ]]; then
      write_report "${name}" "${out}/units/${name}" "${reports}" "${details}" "${work}/report.txt" || report_missing=1
    fi
  done

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
  case "${command}" in
    check) cmd_check ;;
    run) [[ $# -eq 1 ]] || die "Usage: deploy.sh run ENVIRONMENT"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check | run ENVIRONMENT" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
