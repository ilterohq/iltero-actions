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
#   2. terraform plan, saved, and its JSON;
#   3. iltero assure --stage plan;
#   4. iltero assure --stage pre-deploy (linked projects only);
#   5. terraform apply of the saved plan;
#   6. the state after the apply, as JSON;
#   7. iltero assure --stage post-deploy, also after a failed apply.
# The deploy stops at the first step that fails, and exits with its code.
#
# Environment:
#   ILTERO_API_URL   The server's address. The registry audience is built from it.
#   REGISTRY_HOST    The private module registry's host name. Empty: no registry token.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-credentials.sh"

# The variable a unit declares to read other units' state. A deploy always
# sets it to true, so a placeholder can never be deployed.
readonly REMOTE_STATE_SWITCH="enable_remote_state_dependencies"

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
  if [[ "${linked}" == true ]]; then
    [[ -n "${run_id}" && -n "${pins}" ]] \
      || die "This project is linked to Iltero Platform. Deploy it in a governed run: pass the run-id and pins-digest from the open action."
    require_id_token
  else
    [[ -z "${run_id}" && -z "${pins}" ]] \
      || die "This project has no platform section in .iltero/config.yml, so it cannot deploy in a governed run. Leave run-id and pins-digest empty."
    [[ -z "${REGISTRY_HOST:-}" ]] \
      || die "This project has no platform section in .iltero/config.yml, so it cannot use the Iltero module registry."
  fi
}

# Succeeds when a unit declares the remote-state switch variable.
declares_remote_state_switch() {
  local dir="$1"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 1
  grep -qE "^[[:space:]]*variable[[:space:]]+\"${REMOTE_STATE_SWITCH}\"" "${files[@]}"
}

# Runs Terraform with only the variables it needs: PATH, HOME, the cloud's
# credentials and TF_VAR_* values. Extra NAME=value pairs before "--" are
# added to its environment.
terraform_scrubbed() {
  local work="$1"
  shift
  local extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra+=("$1")
    shift
  done
  shift
  local kept=() name
  for name in "${CLOUD_CREDENTIAL_ENV[@]}" $(compgen -e | grep '^TF_VAR_' || true); do
    [[ -z "${!name+set}" ]] || kept+=("${name}=${!name}")
  done
  env -i PATH="${PATH}" HOME="${HOME}" TF_IN_AUTOMATION=1 TF_INPUT=0 TF_DATA_DIR="${work}/terraform-data" \
    ${kept[@]+"${kept[@]}"} ${extra[@]+"${extra[@]}"} "$(terraform_path)" "$@"
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

  local init_args=(-input=false -no-color -lockfile=readonly)
  [[ ! -f "config/backend/${environment}.hcl" ]] || init_args+=(-backend-config="${PWD}/config/backend/${environment}.hcl")
  local plan_args=(-input=false -no-color -out="${work}/tfplan")
  [[ ! -f "config/${environment}.tfvars" ]] || plan_args+=(-var-file="${PWD}/config/${environment}.tfvars")
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
    terraform_scrubbed "${work}" ${token_env[@]+"${token_env[@]}"} -- init "${init_args[@]}" \
      && terraform_scrubbed "${work}" -- plan "${plan_args[@]}" \
      && terraform_scrubbed "${work}" -- show -json "${work}/tfplan" > "${work}/plan.json"
  ) || status=$?
  resume_commands
  token_env=()
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

  local apply_status=0
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" -- apply -input=false -json "${work}/tfplan" > "${work}/apply.ndjson"
  ) || apply_status=$?
  UNIT_RESULTS[2]="exit ${apply_status}"

  if ! (cd "${dir}" && terraform_scrubbed "${work}" -- show -json > "${work}/state.json"); then
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
  local linked
  linked="$(project_linked)"
  check_mode "${linked}" "${run_id}" "${pins}"
  local work_root="${RUNNER_TEMP}/iltero-deploy"
  local out="${work_root}/out"
  local units="${work_root}/units.tsv"
  mkdir -p "${out}"
  write_output out-dir "${out}"

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
    mkdir -p "${work}"
    echo "::group::${name}"
    deploy_unit "${name}" "${dir}" "${work}" "${environment}" "${run_id}" "${pins}" "${out}" || status=$?
    echo "::endgroup::"
    echo "| ${name} | ${UNIT_RESULTS[0]} | ${UNIT_RESULTS[1]} | ${UNIT_RESULTS[2]} | ${UNIT_RESULTS[3]} |" >> "${summary}"
    for stage in plan pre-deploy post-deploy; do
      [[ -f "${work}/${stage}.txt" ]] || continue
      details_block "${name}: ${stage}" "${work}/${stage}.txt" >> "${details}"
    done
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
