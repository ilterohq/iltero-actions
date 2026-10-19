#!/bin/bash
#
# Deploys every unit of a stack.
#
# Usage:
#   deploy.sh check                            Refuse untrusted and pull request events; check that setup ran.
#   deploy.sh run ENVIRONMENT [RUN_ID PINS]    Deploy every unit; write the job summary.
#
# Run from the stack's working directory. A project linked to Iltero Platform
# deploys in the governed run that RUN_ID names. A project with no platform
# section in .iltero/config.yml deploys locally: no run, no upload and no
# pre-deploy stage, and RUN_ID must not be given.
#
# For each unit, in the order `iltero units list` prints:
#   1. terraform init, with a registry token when REGISTRY_HOST is set;
#   2. iltero state check, which refuses a unit that keeps its state in its
#      working directory;
#   3. terraform plan, saved, and its JSON;
#   4. iltero assure --stage plan;
#   5. iltero assure --stage pre-deploy (linked projects only);
#   6. terraform apply of the saved plan;
#   7. the state after the apply, as JSON;
#   8. iltero assure --stage post-deploy, also after a failed apply.
# The deploy stops at the first step that fails, and exits with its code.
# When REPORT is true, the CLI also writes a report of each unit's record.
#
# Environment:
#   REGISTRY_HOST    The private module registry's host name. Empty: no registry token.
#   REPORT           true or false. True: write a report of each unit's record.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-credentials.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/report.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/terraform.sh"

cmd_check() {
  refuse_untrusted_event
  refuse_pull_request
  cli_path > /dev/null
  terraform_path > /dev/null
}

# Stops unless the run inputs fit the project: a linked project deploys only
# in a governed run, and an unlinked one never does.
check_mode() {
  local linked="$1"
  local run_id="$2"
  local pins="$3"
  [[ "${linked}" == true || "${linked}" == false ]] || die "The CLI's config report could not be read."
  [[ -z "${REGISTRY_HOST:-}" ]] || require_linked_for_registry "${linked}"
  if [[ "${linked}" == true ]]; then
    [[ -n "${run_id}" && -n "${pins}" ]] \
      || die "This project is linked to Iltero Platform. Deploy it in a governed run: pass the run-id and pins-digest from the open action."
    require_id_token
  else
    [[ -z "${run_id}" && -z "${pins}" ]] \
      || die "This project has no platform section in .iltero/config.yml, so it cannot deploy in a governed run. Leave run-id and pins-digest empty."
  fi
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

# Runs one CLI stage for a unit. Prints its output and keeps a copy for the
# summary. Returns the CLI's exit code.
assure_stage() {
  local work="$1"
  local stage="$2"
  shift 2
  local cli tools status=0
  cli="$(cli_path)"
  tools="$(tools_dir)"
  ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" assure --stage="${stage}" "$@" \
    > "${work}/${stage}.txt" 2>&1 || status=$?
  print_untrusted "${work}/${stage}.txt"
  return "${status}"
}

# Runs the CLI's state check, which refuses a unit that keeps its Terraform
# state in its working directory, where the state is lost with the runner.
# Returns the CLI's exit code.
state_check() {
  local dir="$1"
  local work="$2"
  local status=0
  TF_DATA_DIR="$(terraform_data_dir "${work}")" "$(cli_path)" state check --dir="${dir}" \
    > "${work}/state-check.txt" 2>&1 || status=$?
  print_untrusted "${work}/state-check.txt"
  return "${status}"
}

# Deploys one unit. Sets UNIT_RESULTS to its summary row cells. Returns the
# code of the first step that failed.
deploy_unit() {
  local name="$1"
  local dir="$2"
  local work="$3"
  local environment="$4"
  local run_id="$5"
  local pins="$6"
  local out="$7"
  local run_args=(--unit="${name}" --out="${out}")
  [[ -z "${run_id}" ]] || run_args+=(--run-id="${run_id}" --pins-digest="${pins}" --upload)
  local plan_files=(--plan="${work}/plan.json" --plan-binary="${work}/tfplan")
  UNIT_RESULTS=("-" "-" "-" "-")

  local backend_config var_file
  backend_config="$(unit_backend_config "${dir}" "${environment}")"
  var_file="$(unit_var_file "${dir}" "${environment}")"
  local init_args=(-input=false -no-color -lockfile=readonly)
  [[ ! -f "${backend_config}" ]] || init_args+=(-backend-config="${backend_config}")
  local plan_args=(-input=false -no-color -out="${work}/tfplan")
  [[ ! -f "${var_file}" ]] || plan_args+=(-var-file="${var_file}")
  if declares_remote_state_switch "${dir}"; then
    # Set from a variables file, not -var: Terraform records a -var value in
    # the plan as a string. The file comes last, so it wins.
    echo "${REMOTE_STATE_SWITCH} = true" > "${work}/with-upstream.tfvars" || return 1
    plan_args+=(-var-file="${work}/with-upstream.tfvars")
  fi

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
  state_check "${dir}" "${work}" || status=$?
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

  assure_stage "${work}" plan "${plan_files[@]}" --environment="${environment}" "${run_args[@]}" || status=$?
  UNIT_RESULTS[0]="exit ${status}"
  [[ "${status}" -eq 0 ]] || return "${status}"

  # Pre-deploy checks facts only Iltero Platform holds, so it runs only in a
  # governed run.
  if [[ -n "${run_id}" ]]; then
    assure_stage "${work}" pre-deploy "${run_args[@]}" || status=$?
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
  assure_stage "${work}" post-deploy "${plan_files[@]}" --apply-log="${work}/apply.ndjson" \
    --state="${work}/state.json" "${run_args[@]}" || status=$?
  UNIT_RESULTS[3]="exit ${status}"
  [[ "${apply_status}" -eq 0 ]] || return "${apply_status}"
  return "${status}"
}

cmd_run() {
  local environment="$1"
  local run_id="${2:-}"
  local pins="${3:-}"
  local linked report
  report="$(report_enabled)"
  linked="$(project_linked)"
  check_mode "${linked}" "${run_id}" "${pins}"
  local work_root="${RUNNER_TEMP}/iltero-deploy"
  local out="${work_root}/out"
  local units="${work_root}/units.tsv"
  local reports="${work_root}/reports"
  mkdir -p "${out}"
  write_output out-dir "${out}"
  if [[ "${report}" == true ]]; then
    mkdir -p "${reports}"
    write_output report-dir "${reports}"
  fi

  list_checked_units "${units}"

  local summary="${work_root}/summary.md" details="${work_root}/details.md"
  {
    echo "## Iltero deploy: $(markdown_escape "${environment}")"
    echo
    echo "| Unit | Plan | Pre-deploy | Apply | Post-deploy |"
    echo "| --- | --- | --- | --- | --- |"
  } > "${summary}"
  : > "${details}"

  local name dir work status=0 failed_unit="" stage
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    rm -rf "${work}"
    mkdir -p "${work}"
    echo "::group::${name}"
    deploy_unit "${name}" "${dir}" "${work}" "${environment}" "${run_id}" "${pins}" "${out}" || status=$?
    echo "::endgroup::"
    echo "| ${name} | ${UNIT_RESULTS[0]} | ${UNIT_RESULTS[1]} | ${UNIT_RESULTS[2]} | ${UNIT_RESULTS[3]} |" >> "${summary}"
    for stage in state-check plan pre-deploy post-deploy; do
      [[ -f "${work}/${stage}.txt" ]] || continue
      details_block "${name}: ${stage}" "${work}/${stage}.txt" >> "${details}"
    done
    if [[ "${report}" == true && -f "${out}/units/${name}/car.json" ]]; then
      write_report "${name}" "${out}/units/${name}" "${reports}" "${details}" "${work}/report.txt"
    fi
    if [[ "${status}" -ne 0 ]]; then
      failed_unit="${name}"
      break
    fi
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
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    run) [[ $# -eq 3 ]] || die "Usage: deploy.sh run ENVIRONMENT RUN_ID PINS_DIGEST (empty for a local deploy)"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check | run ENVIRONMENT RUN_ID PINS_DIGEST" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
