#!/bin/bash
#
# Helpers shared by every action. Source this file; it defines functions and
# constants, and turns off one Bash option.

# Bash 5.2 and later read "&" in a replacement as the matched text. Every
# replacement here means a literal "&". Older Bash has no such option.
shopt -u patsub_replacement 2> /dev/null || true

# The folder under the runner's temporary directory where `setup` installs the
# tools. Every action finds the tools here, by absolute path.
readonly ILTERO_TOOLS_DIRNAME="iltero-tools"

# Characters for patterns, listed one by one: a range such as a-z can also
# match capital letters, depending on the locale.
readonly LOWER="abcdefghijklmnopqrstuvwxyz"
readonly HEX="0123456789abcdef"
# A full git commit: 40 lowercase hex characters.
readonly COMMIT_PATTERN="^[${HEX}]{40}$"
# A SHA-256 digest: 64 lowercase hex characters.
readonly SHA256_PATTERN="^[${HEX}]{64}$"
# The unit-name rule the CLI applies.
readonly UNIT_NAME_PATTERN="^[${LOWER}0-9_][${LOWER}0-9_-]{0,63}$"

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

# Prints the absolute path of the Terraform binary that `setup` installed.
terraform_path() {
  local terraform
  terraform="$(tools_dir)/bin/terraform"
  [[ -x "${terraform}" ]] || die "Terraform is not installed. Run the setup action first in this job."
  echo "${terraform}"
}

# Escapes text for HTML in the job summary and the pull request comment, so
# text from a tool cannot change how they render or mention anyone.
html_escape() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  text="${text//@/&#64;}"
  echo "${text}"
}

# Prints one collapsible section of the job summary: TITLE, then the escaped
# text of FILE. The blank lines keep the text inside the <pre> block when it
# has blank lines of its own.
details_block() {
  local title="$1"
  local file="$2"
  echo "<details><summary>${title}</summary>"
  echo
  echo "<pre>"
  html_escape "$(cat "${file}")"
  echo "</pre>"
  echo
  echo "</details>"
}

# Turns workflow commands off until resume_commands, so a line of tool output
# cannot act as one. Terraform's output and the CLI's check output run with
# commands off. The CLI's CI commands (run, environment detect, config show)
# keep them on: the CLI escapes the text it prints and may hide a value.
pause_commands() {
  COMMANDS_TOKEN="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  echo "::stop-commands::${COMMANDS_TOKEN}"
}

resume_commands() {
  echo "::${COMMANDS_TOKEN}::"
}

# Prints files of tool output with workflow commands turned off.
print_untrusted() {
  pause_commands
  cat "$@"
  resume_commands
}

# Stops unless NAME is a valid artifact name that can also sit inside the
# preview comment's marker.
check_artifact_name() {
  local name="$1"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Invalid artifact name '${name}'. Use letters, digits, '.', '_' and '-'."
}

# Escapes text for a line of Markdown, such as a heading: HTML as html_escape
# does, then each punctuation mark Markdown reads, so the text shows as it is.
markdown_escape() {
  local text out="" char i
  local marks='\`*_{}[]()+-.!|~"'"'"'$%,/:=?^'
  text="$(html_escape "$1")"
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    if [[ "${marks}" == *"${char}"* ]]; then
      out+="\\${char}"
    else
      out+="${char}"
    fi
  done
  echo "${out}"
}

# Prints the address of this workflow run's page.
run_url() {
  [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]] \
    || die "GITHUB_SERVER_URL, GITHUB_REPOSITORY or GITHUB_RUN_ID is not set. Run this action inside a GitHub Actions job."
  echo "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
}

# Writes one step output. The value must be a single line, so it cannot add
# other outputs.
write_output() {
  local name="$1"
  local value="$2"
  [[ "${name}" =~ ^[${LOWER}][${LOWER}0-9-]*$ ]] || die "Invalid output name '${name}'."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "The value of output '${name}' spans several lines."
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die "GITHUB_OUTPUT is not set. Run this action inside a GitHub Actions job."
  echo "${name}=${value}" >> "${GITHUB_OUTPUT}"
}
