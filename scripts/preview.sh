#!/bin/bash
#
# Checks each unit's plan locally, with no cloud credential. Nothing is sent
# to Iltero. With REGISTRY_HOST set, terraform init alone gets a short-lived
# token to download modules from the private module registry.
#
# Usage:
#   preview.sh check ARTIFACT_NAME    Refuse events other than pull_request and a bad artifact name;
#                                     check that setup ran and, with REGISTRY_HOST set, that the host
#                                     is valid and the job can request its identity token.
#   preview.sh environment            Write the comment that stands until the run ends, then ask the
#                                     CLI which environment the change targets. The CLI writes the output.
#   preview.sh run ENVIRONMENT        Plan and check every unit; write the job summary and the
#                                     pull request comment that the comment action posts.
#
# Run from the stack's working directory. The units, and their order, are the
# ones `iltero units list` prints, as for deploy and verify.
#
# A unit that reads other units' remote state can declare the variable
# enable_remote_state_dependencies. It is then planned with that variable set
# to false, without upstream state, and its result is labelled best effort.
# A unit that cannot be planned without credentials is reported as not
# evaluated, and the step fails.
#
# Environment:
#   REGISTRY_HOST    The private module registry's host name. Empty: no registry token.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/preview-providers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/terraform.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"

# The override file the action adds to a unit while it plans it.
readonly OVERRIDE_FILE="zzz_iltero_preview_override.tf"
# The longest comment the action writes. GitHub accepts up to 65536
# characters; the rest is room for the comment action's marker.
readonly COMMENT_MAX_CHARS=60000

cmd_check() {
  local artifact_name="$1"
  refuse_untrusted_event
  [[ "${GITHUB_EVENT_NAME}" == pull_request ]] \
    || die "The preview action runs only on pull_request events."
  check_artifact_name "${artifact_name}"
  [[ "${UPLOAD_RECORDS:-}" == true || "${UPLOAD_RECORDS:-}" == false ]] \
    || die "The upload-records input must be true or false, not '${UPLOAD_RECORDS:-}'."
  cli_path > /dev/null
  terraform_path > /dev/null
  if [[ -n "${REGISTRY_HOST:-}" ]]; then
    registry_token_variable "${REGISTRY_HOST}" > /dev/null
    [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
      || die "The job cannot request its identity token for the module registry. Grant it 'permissions: id-token: write'. By default, GitHub gives no identity token to a pull request from a fork."
  fi
}

# Writes the comment that stands until the run writes its result, so an
# earlier result is never left showing for a newer commit.
cmd_environment() {
  local cli dir linked
  cli="$(cli_path)"
  if [[ -n "${REGISTRY_HOST:-}" ]]; then
    linked="$(project_linked)"
    require_linked_for_registry "${linked}"
  fi
  dir="$(comment_dir)"
  write_comment "${dir}"
  write_output comment-dir "${dir}"
  "${cli}" environment detect --format=github-actions
}

# Prints the directory that holds the pull request comment.
comment_dir() {
  echo "${RUNNER_TEMP}/iltero-preview/comment"
}

# Runs Terraform with the provider adapter's settings added to what
# run_terraform keeps. Takes run_terraform's arguments.
terraform_scrubbed() {
  local work="$1"
  shift
  run_terraform "${work}" ${PREVIEW_PROVIDER_ENV[@]+"${PREVIEW_PROVIDER_ENV[@]}"} "$@"
}

# Plans one unit with no credentials. Writes tfplan and plan.json under WORK.
# TOKEN_ENV, when given, is a NAME=VALUE that reaches only the init process.
# Sets PLANNED_WITHOUT_UPSTREAM to true when the remote-state switch was off.
# Returns non-zero, with the reason on stderr, when the unit cannot be planned.
plan_unit() {
  local dir="$1"
  local work="$2"
  local var_file="$3"
  local token_env="${4:-}"
  local override="${dir}/${OVERRIDE_FILE}"

  [[ ! -e "${override}" ]] || { echo "The unit already has a file named ${OVERRIDE_FILE}." >&2; return 1; }
  preview_override "${dir}" > "${work}/override.tf" || return 1
  cp "${work}/override.tf" "${override}" || return 1

  local args=(-input=false -refresh=false -lock=false -out="${work}/tfplan")
  [[ -z "${var_file}" ]] || args+=(-var-file="${var_file}")
  PLANNED_WITHOUT_UPSTREAM=false
  if declares_remote_state_switch "${dir}"; then
    # Set from a variables file, not -var: Terraform records a -var value in
    # the plan as a string, and a file value as its own type. The file comes
    # last, so it wins over the environment's variables file.
    echo "${REMOTE_STATE_SWITCH} = false" > "${work}/without-upstream.tfvars"
    args+=(-var-file="${work}/without-upstream.tfvars")
    PLANNED_WITHOUT_UPSTREAM=true
  fi

  # Terraform writes a lock file when the unit has none. It is removed after,
  # and a committed one is only read, so the checkout is left as it was.
  local lock="${dir}/.terraform.lock.hcl"
  local had_lock=false
  local init_args=(-input=false -no-color)
  if [[ -e "${lock}" ]]; then
    had_lock=true
    init_args+=(-lockfile=readonly)
  fi

  local status=0
  (
    cd "${dir}" || exit 1
    terraform_scrubbed "${work}" ${token_env:+"${token_env}"} -- init "${init_args[@]}" \
      > "${work}/terraform.log" 2>&1 \
      && terraform_scrubbed "${work}" -- plan -no-color "${args[@]}" >> "${work}/terraform.log" 2>&1 \
      && terraform_scrubbed "${work}" -- show -json "${work}/tfplan" > "${work}/plan.json" 2>> "${work}/terraform.log"
  ) || status=$?
  rm -f "${override}"
  [[ "${had_lock}" == true ]] || rm -f "${lock}"
  if [[ "${status}" -ne 0 ]]; then
    cat "${work}/terraform.log" >&2
    echo "Terraform could not plan the unit without credentials." >&2
    return 1
  fi
}

# Writes the pull request comment into DIR: the summary, each unit's output
# when it fits, the commit, and a link to the job summary. Without SUMMARY and
# DETAILS, it says the preview has not finished.
write_comment() {
  local dir="$1"
  local summary="${2:-}"
  local details="${3:-}"
  local url text
  url="$(run_url)"
  [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "HEAD_SHA is not the pull request's head commit."
  mkdir -p "${dir}"
  if [[ -z "${summary}" ]]; then
    text="## Iltero preview"$'\n\n'"The preview has not finished."
  else
    text="$(cat "${summary}")"$'\n\n'"$(cat "${details}")"
    if [[ "${#text}" -gt "${COMMENT_MAX_CHARS}" ]]; then
      text="$(cat "${summary}")"$'\n\n'"The CLI's output is too long for a comment."
    fi
  fi
  printf '%s\n\nCommit %s. [See the job summary](%s)\n' "${text}" "${HEAD_SHA}" "${url}" > "${dir}/comment.md"
}

cmd_run() {
  local environment="$1"
  local cli tools work_root out summary
  cli="$(cli_path)"
  tools="$(tools_dir)"
  work_root="${RUNNER_TEMP}/iltero-preview"
  out="${work_root}/out"
  summary="${work_root}/summary.md"
  mkdir -p "${out}"
  write_output out-dir "${out}"

  local var_file=""
  [[ ! -f "config/${environment}.tfvars" ]] || var_file="${PWD}/config/${environment}.tfvars"

  {
    echo "## Iltero preview: $(markdown_escape "${environment}")"
    echo
    echo "| Unit | Result |"
    echo "| --- | --- |"
  } > "${summary}"
  local details="${work_root}/details.md"
  : > "${details}"

  # Listed and checked before the loop, so a bad unit stops the step.
  local units="${work_root}/units.tsv"
  list_checked_units "${units}"

  local failed=0 name dir work status result token_env
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    mkdir -p "${work}"
    echo "::group::${name}"
    # A fresh registry token for each init: it lives only a few minutes.
    # Minted here, not in plan_unit, so a failure stops the step.
    token_env=""
    if [[ -n "${REGISTRY_HOST:-}" ]]; then
      mint_registry_token "${REGISTRY_HOST}"
      token_env="${REGISTRY_TOKEN_ENV}"
      REGISTRY_TOKEN_ENV=""
    fi
    if ! plan_unit "${dir}" "${work}" "${var_file}" "${token_env}" 2> "${work}/reason.txt"; then
      print_untrusted "${work}/reason.txt" >&2
      result="not evaluated: the plan could not be made without credentials"
      failed=1
    else
      status=0
      ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" assure --stage=plan \
        --plan="${work}/plan.json" --plan-binary="${work}/tfplan" \
        --environment="${environment}" --unit="${name}" --out="${out}" > "${work}/assure.txt" 2>&1 || status=$?
      print_untrusted "${work}/assure.txt"
      result="exit ${status}"
      [[ "${PLANNED_WITHOUT_UPSTREAM}" != true ]] || result+=" (best effort: planned without upstream state)"
      [[ "${status}" -eq 0 ]] || failed=1
      details_block "${name}" "${work}/assure.txt" >> "${details}"
    fi
    token_env=""
    echo "::endgroup::"
    echo "| ${name} | ${result} |" >> "${summary}"
  done < "${units}"

  {
    cat "${summary}"
    echo
    cat "${details}"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  write_comment "$(comment_dir)" "${summary}" "${details}"
  [[ "${failed}" -eq 0 ]] || die "One or more units failed or were not evaluated. See the job summary."
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) [[ $# -eq 1 ]] || die "Usage: preview.sh check ARTIFACT_NAME"; cmd_check "$@" ;;
    environment) cmd_environment ;;
    run) [[ $# -eq 1 ]] || die "Usage: preview.sh run ENVIRONMENT"; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check ARTIFACT_NAME | environment | run ENVIRONMENT" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
