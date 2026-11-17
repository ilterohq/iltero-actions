#!/bin/bash
#
# Checks each unit's plan locally, with no cloud credential. The CLI sends
# nothing to the server. With REGISTRY_HOST set, the tool's init alone gets a
# short-lived token to download modules from the private module registry.
#
# Usage:
#   iac/preview.sh check ARTIFACT_NAME  Refuse events other than pull_request and a bad artifact name;
#                                       check that setup ran and, with REGISTRY_HOST set, that the host
#                                       is valid and the job can request its identity token.
#   iac/preview.sh environment          Write the comment that stands until the run ends, then write the
#                                       environment output: ENVIRONMENT when set, otherwise the one the CLI
#                                       finds from the pull request's target branch.
#   iac/preview.sh run ENVIRONMENT      Plan and check every unit; write the job summary and the
#                                       pull request comment that the comment action posts.
#
# Run from the stack's working directory. The units, and their order, are the
# ones `iltero units list` prints, as for deploy and verify.
#
# A unit that reads other units' remote state can declare the tool's
# remote-state switch, which the tool's adapter names. It is then planned with
# the switch off,
# without upstream state, and its result says it was planned without the
# state of the units it reads.
# A unit that cannot be planned is reported as not evaluated, and the step
# fails.
#
# Environment:
#   TOOL             The IaC tool the stack uses: one of SUPPORTED_TOOLS in lib/tool.sh.
#   ENVIRONMENT      The environment to check against. Empty: the CLI finds it from the target branch.
#   REGISTRY_HOST    The private module registry's host name. Empty: no registry token.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cli-stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/stages.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/project.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/cloud-credentials.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/guard.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/tool.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/units.sh"

# The longest comment the action writes. GitHub accepts up to 65536
# characters; the rest is room for the comment action's marker.
readonly COMMENT_MAX_CHARS=60000
# The comment that stands until the run writes its result.
readonly COMMENT_NOT_FINISHED="The preview has not finished."
# The comment when the preview stops before it writes its result.
readonly COMMENT_STOPPED="The preview stopped before it checked every unit. See the job summary and the log."

cmd_check() {
  local artifact_name="$1"
  refuse_untrusted_event
  [[ "${GITHUB_EVENT_NAME}" == pull_request ]] \
    || die "The preview action runs only on pull_request events."
  check_artifact_name "${artifact_name}"
  require_true_or_false upload-records "${UPLOAD_RECORDS:-}"
  cli_path > /dev/null
  if [[ -n "${REGISTRY_HOST:-}" ]]; then
    check_registry_host "${REGISTRY_HOST}"
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
  write_status_comment "${dir}" "${COMMENT_NOT_FINISHED}"
  write_output comment-directory "${dir}"
  # From here, a failure replaces the comment, so it never says the preview is
  # still running.
  RESULT_COMMENT_WRITTEN=false
  trap replace_comment_on_failure EXIT
  # A branch that deploys to several environments matches several rules, and
  # the CLI does not choose one, so the workflow names it.
  if [[ -n "${ENVIRONMENT:-}" ]]; then
    require_environment_name "${ENVIRONMENT}"
    write_output environment "${ENVIRONMENT}"
    return 0
  fi
  local status=0
  "${cli}" environment detect --format=github-actions || status=$?
  [[ "${status}" -ne 2 ]] \
    || echo "::notice::When the target branch deploys to several environments, name one with the preview action's environment input."
  return "${status}"
}

# Sets PREVIEW_WORK_ROOT to the work folder of the stack in the current
# folder. Each stack has its own, so two previews in one job keep their files
# apart.
set_preview_work_root() {
  local temp stack
  temp="$(runner_temp)" || exit 1
  stack="$(stack_work_folder_name)" || die "The action could not name the stack's work folder."
  readonly PREVIEW_WORK_ROOT="${temp}/iltero-preview/${stack}"
}

# Prints the directory that holds the pull request comment.
comment_dir() {
  echo "${PREVIEW_WORK_ROOT}/comment"
}

# Writes TEXT as the pull request comment into DIR, with the commit and a link
# to the job summary.
write_comment() {
  local dir="$1"
  local text="$2"
  local url
  url="$(run_url)"
  [[ "${HEAD_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "HEAD_SHA is not the pull request's head commit."
  mkdir -p "${dir}"
  printf '%s\n\nCommit %s. [See the job summary](%s)\n' "${text}" "${HEAD_SHA}" "${url}" > "${dir}/comment.md"
}

# Writes a comment in DIR that says only MESSAGE about the preview.
write_status_comment() {
  write_comment "$1" "## Iltero preview"$'\n\n'"$2"
}

# Writes the comment in DIR with the result: the SUMMARY file, and the DETAILS
# file when the whole comment fits.
write_result_comment() {
  local dir="$1"
  local summary="$2"
  local details="$3"
  local text
  text="$(cat "${summary}")"$'\n\n'"$(cat "${details}")"
  if [[ "${#text}" -gt "${COMMENT_MAX_CHARS}" ]]; then
    text="$(cat "${summary}")"$'\n\n'"The CLI's output is too long for a comment."
  fi
  # With very many units, the result table alone can be too long for a comment.
  if [[ "${#text}" -gt "${COMMENT_MAX_CHARS}" ]]; then
    text="$(head -n 1 "${summary}")"$'\n\n'"The result is too long for a comment."
  fi
  write_comment "${dir}" "${text}"
}

# Replaces the comment when a step stops before the run writes its result, so
# the comment never says the preview is still running.
replace_comment_on_failure() {
  local status=$?
  trap - EXIT
  [[ "${status}" -eq 0 || "${RESULT_COMMENT_WRITTEN}" == true ]] || write_status_comment "$(comment_dir)" "${COMMENT_STOPPED}"
  exit "${status}"
}

cmd_run() {
  local environment="$1"
  local work_root out summary
  RESULT_COMMENT_WRITTEN=false
  trap replace_comment_on_failure EXIT
  require_environment_name "${environment}"
  work_root="${PREVIEW_WORK_ROOT}"
  out="${work_root}/out"
  # The action removes the records and unit files of an earlier preview, so
  # none is taken for one this preview wrote. It keeps the comment, which the
  # step that finds the environment wrote.
  rm -rf "${out}" "${work_root}/units"
  summary="${work_root}/summary.md"
  mkdir -p "${out}"
  # The action checks the unit list before it writes any output. When the
  # list fails its checks, the step writes no output, and the upload step
  # does not run.
  local units="${work_root}/units.tsv"
  list_checked_units "${units}"
  write_output records-directory "${out}"

  {
    echo "## Iltero preview: $(markdown_escape "${environment}")"
    echo
    echo "| Unit | Result |"
    echo "| --- | --- |"
  } > "${summary}"
  local details="${work_root}/details.md"
  : > "${details}"

  trust_paths "${out}" "${units}" "${summary}" "${details}"

  local first_status=0 name dir work status result token_env
  while IFS=$'\t' read -r name dir; do
    work="${work_root}/units/${name}"
    # Each unit starts with an empty work directory, so no earlier output shows.
    rm -rf "${work}"
    mkdir -p "${work}"
    echo "::group::${name}"
    if ! tool_check_environment_settings "${dir}" "${environment}" 2> "${work}/reason.txt"; then
      print_untrusted "${work}/reason.txt" >&2
      result="not evaluated: the unit is not set up for this environment"
      [[ "${first_status}" -ne 0 ]] || first_status=1
    else
      # A fresh registry token for each init: it lives only a few minutes.
      # Minted here, not in tool_preview_plan, so a failure stops the step.
      token_env=""
      if [[ -n "${REGISTRY_HOST:-}" ]]; then
        mint_registry_token "${REGISTRY_HOST}" || {
          echo "::endgroup::"
          exit 1
        }
        token_env="${REGISTRY_TOKEN_ENV}"
        REGISTRY_TOKEN_ENV=""
      fi
      if ! tool_preview_plan "${work}" "${dir}" "${environment}" "${token_env}" 2> "${work}/reason.txt"; then
        print_untrusted "${work}/reason.txt" >&2
        result="not evaluated: the preview could not plan the unit"
        [[ "${first_status}" -ne 0 ]] || first_status=1
      else
        status=0
        # A pull request's check stays local, never on the server, linked or not.
        check_stage "${work}" plan --plan="${work}/plan.json" --saved-plan="${work}/${TOOL_SAVED_PLAN_FILE}" \
          --environment="${environment}" --unit="${name}" --out="${out}" --local || status=$?
        result="$(check_result "${status}")"
        [[ "${PLANNED_WITHOUT_UPSTREAM}" != true ]] \
          || result+=" (planned without the state of the units it reads, so the result can differ after the merge)"
        [[ "${status}" -eq 0 || "${first_status}" -ne 0 ]] || first_status="${status}"
        append_details_block "${details}" "${name}" "${work}/plan.txt"
      fi
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
  write_result_comment "$(comment_dir)" "${summary}" "${details}"
  RESULT_COMMENT_WRITTEN=true
  [[ "${first_status}" -eq 0 ]] \
    || exit_with_error "${first_status}" "One or more units failed or were not evaluated. See the job summary."
}

# Prints the address of this workflow run's page on GitHub.
run_url() {
  [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]] \
    || die "GITHUB_SERVER_URL, GITHUB_REPOSITORY or GITHUB_RUN_ID is not set. Run this action inside a GitHub Actions job."
  echo "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
}

main() {
  local command="${1:-}"
  shift || true
  load_tool "${TOOL:-}"
  # The tool gets only mock credentials. The adapter reads them.
  # shellcheck disable=SC2034
  readonly TOOL_ENVIRONMENT_PAIRS=(${PREVIEW_CREDENTIAL_ENV[@]+"${PREVIEW_CREDENTIAL_ENV[@]}"})
  case "${command}" in
    check) [[ $# -eq 1 ]] || die "Usage: iac/preview.sh check ARTIFACT_NAME"; cmd_check "$@" ;;
    environment) set_preview_work_root; cmd_environment ;;
    run) [[ $# -eq 1 ]] || die "Usage: iac/preview.sh run ENVIRONMENT"; set_preview_work_root; cmd_run "$@" ;;
    *) die "Unknown command '${command}'. Use: check ARTIFACT_NAME | environment | run ENVIRONMENT" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # A stop signal, such as the one stop_step sends, ends the step as failed,
  # after any exit trap.
  trap 'exit 143' TERM
  main "$@"
fi
