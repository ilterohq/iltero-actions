#!/bin/bash
#
# Helpers shared by every action. Source this file; it defines functions only.

# The folder under the runner's temporary directory where `setup` installs the
# tools. Every action finds the tools here, by absolute path.
readonly ILTERO_TOOLS_DIRNAME="iltero-tools"

# Prints an error annotation and exits with status 1. The message is escaped,
# so a value inside it cannot start another workflow command.
die() {
  local message="$*"
  message="${message//%/%25}"
  message="${message//$'\r'/%0D}"
  message="${message//$'\n'/%0A}"
  printf '::error::%s\n' "${message}" >&2
  exit 1
}

# Prints the absolute path of the tools folder.
tools_dir() {
  [[ -n "${RUNNER_TEMP:-}" ]] || die "RUNNER_TEMP is not set. Run this action inside a GitHub Actions job."
  echo "${RUNNER_TEMP}/${ILTERO_TOOLS_DIRNAME}"
}

# Refuses the events under which a workflow runs untrusted code with the
# repository's own permissions. Every action calls this first.
refuse_untrusted_event() {
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request_target | workflow_run)
      die "Iltero actions do not run on '${GITHUB_EVENT_NAME}' events."
      ;;
    "")
      die "GITHUB_EVENT_NAME is not set. Run this action inside a GitHub Actions job."
      ;;
    *) ;;
  esac
}

# Refuses pull request events. A pull request may only run a local preview,
# never a governed run.
refuse_pull_request() {
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_review | pull_request_review_comment)
      die "This action does not run on pull request events. Use the preview action instead."
      ;;
    *) ;;
  esac
}

# Stops unless the job may request its GitHub identity token, which the CLI
# fetches itself.
require_id_token() {
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
    || die "The job cannot request its identity token. Grant it 'permissions: id-token: write'."
}

# Prints the absolute path of the CLI that `setup` installed.
cli_path() {
  local cli
  cli="$(tools_dir)/venv/bin/iltero"
  [[ -x "${cli}" ]] || die "The Iltero CLI is not installed. Run the setup action first in this job."
  echo "${cli}"
}

# Writes one step output. The value must be a single line, so it cannot add
# other outputs.
write_output() {
  local name="$1"
  local value="$2"
  [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || die "Invalid output name '${name}'."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "The value of output '${name}' spans several lines."
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die "GITHUB_OUTPUT is not set. Run this action inside a GitHub Actions job."
  echo "${name}=${value}" >> "${GITHUB_OUTPUT}"
}
