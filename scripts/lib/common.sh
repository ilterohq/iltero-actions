#!/bin/bash
#
# Helpers shared by every action. Source this file; it defines functions and
# constants, and turns off one Bash option.

# Bash 5.2 and later read "&" in a replacement as the matched text. Every
# replacement here means a literal "&". Older Bash has no such option.
shopt -u patsub_replacement 2> /dev/null || true

# The folder under the runner's temporary directory where `setup` installs the
# CLI and its evaluator, and where deploy and preview install Terraform. Every
# action finds the tools here, by absolute path.
readonly ILTERO_TOOLS_DIRECTORY_NAME="iltero-tools"
# The scanner folder, inside the tools folder, where the CLI keeps the
# scanners it installs. The runner empties it for each job, so no scanner is
# kept between jobs.
readonly SCANNER_DIRECTORY_NAME="scanners"

# Characters for patterns, listed one by one: a range such as a-z can also
# match capital letters, depending on the locale.
readonly LOWERCASE_LETTERS="abcdefghijklmnopqrstuvwxyz"
readonly UPPERCASE_LETTERS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
readonly DIGITS="0123456789"
readonly LOWERCASE_HEX_DIGITS="0123456789abcdef"
# A name that can name a directory, a file and an artifact: letters, digits,
# ".", "_" and "-".
readonly PORTABLE_NAME_PATTERN="^[${LOWERCASE_LETTERS}${UPPERCASE_LETTERS}${DIGITS}._-]+$"
# A full git commit ID: 40 lowercase hexadecimal digits. Used by the scripts
# that source this file.
# shellcheck disable=SC2034
readonly COMMIT_PATTERN="^[${LOWERCASE_HEX_DIGITS}]{40}$"
# A SHA-256 digest: 64 lowercase hexadecimal digits.
# shellcheck disable=SC2034
readonly SHA256_PATTERN="^[${LOWERCASE_HEX_DIGITS}]{64}$"
# Succeeds when NAME can name a directory, a file and an artifact: it follows
# PORTABLE_NAME_PATTERN, and is not "." or "..".
is_portable_name() {
  local name="$1"
  [[ "${name}" =~ ${PORTABLE_NAME_PATTERN} && "${name}" != . && "${name}" != .. ]]
}

# Stops unless the unit name NAME can name a directory, a file and an
# artifact, as the actions name a unit's work folder, records and artifacts
# after it. The CLI applies its own rule for unit names.
check_unit_name() {
  local name="$1"
  is_portable_name "${name}" \
    || die "The unit name '${name}' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."
}

# Prints LINE without the spaces at its start and end.
trim() {
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  printf '%s\n' "${line%"${line##*[![:space:]]}"}"
}

# Prints an error annotation and exits with STATUS. The message is escaped,
# so a value inside it cannot start another workflow command.
exit_with_error() {
  local status="$1"
  shift
  local message="$*"
  message="${message//%/%25}"
  message="${message//$'\r'/%0D}"
  message="${message//$'\n'/%0A}"
  printf '::error::%s\n' "${message}" >&2
  exit "${status}"
}

# Prints the summary word for a check that ended with STATUS: "passed" or
# "failed". The summary never shows the code itself; the CLI's own lines in
# the details say why a check failed.
check_result() {
  if [[ "${1}" == 0 ]]; then
    echo passed
  else
    echo failed
  fi
}

# Prints an error annotation and exits with status 1.
die() {
  exit_with_error 1 "$@"
}

# Stops unless the input INPUT, whose value is VALUE, is true or false.
require_true_or_false() {
  local input="$1"
  local value="$2"
  [[ "${value}" == true || "${value}" == false ]] || die "The ${input} input must be true or false, not '${value}'."
}

# Stops unless the input INPUT, whose value is VALUE, is one line, with no
# tab or other control character.
require_one_line() {
  local input="$1"
  local value="$2"
  [[ "${value}" != *[[:cntrl:]]* ]] || die "The ${input} input must be one line, with no tab or other control character."
}

# Stops unless ENVIRONMENT can name a directory, a file and an artifact, as
# the actions name records directories, artifacts and a unit's settings files
# after it.
require_environment_name() {
  local environment="$1"
  [[ -n "${environment}" ]] || die "The environment input is required."
  require_one_line environment "${environment}"
  is_portable_name "${environment}" \
    || die "The environment '${environment}' cannot name a directory or a file. Use only letters, digits, '.', '_' and '-', and not '.' or '..' alone."
}

# How many hexadecimal digits of the digest of the stack's folder path go into
# the name of its work folder.
readonly STACK_FOLDER_DIGEST_LENGTH=12

# Prints the name of the work folder of the stack in the current folder. Every
# step that runs in the same folder gets the same name. Two stacks in one job
# get different names, so they keep their files apart.
stack_work_folder_name() {
  local digest
  digest="$(printf '%s' "${PWD}" | sha256sum)" || return 1
  echo "stack-${digest:0:${STACK_FOLDER_DIGEST_LENGTH}}"
}

# Prints the absolute path of the tools folder.
tools_dir() {
  local temp
  temp="$(runner_temp)" || return 1
  echo "${temp}/${ILTERO_TOOLS_DIRECTORY_NAME}"
}

# Prints the absolute path of the scanner folder.
scanner_dir() {
  local tools
  tools="$(tools_dir)" || return 1
  echo "${tools}/${SCANNER_DIRECTORY_NAME}"
}

# Prints the runner's folder for temporary files, or stops when the runner
# did not set it.
runner_temp() {
  [[ -n "${RUNNER_TEMP:-}" ]] || die "RUNNER_TEMP is not set. Run this action inside a GitHub Actions job."
  echo "${RUNNER_TEMP}"
}

# Refuses the events under which a workflow runs untrusted code with the
# repository's own permissions. Every action calls this first.
refuse_untrusted_event() {
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request_target | workflow_run)
      die "Iltero actions do not run on '${GITHUB_EVENT_NAME}' events. Run them on pull_request events for a pull request, or after the merge."
      ;;
    "")
      die "GITHUB_EVENT_NAME is not set. Run this action inside a GitHub Actions job."
      ;;
    *) ;;
  esac
}

# Succeeds when the job runs on a pull request event.
is_pull_request_event() {
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request | pull_request_review | pull_request_review_comment) return 0 ;;
    *) return 1 ;;
  esac
}

# Stops unless ACTION records STAGE, one of the STAGES that follow, on the
# job's event. It refuses pull_request_target and workflow_run first, then
# pull_request_review and pull_request_review_comment events. On
# pull_request events it allows only the plan stage, which checks SUBJECT
# locally.
check_stage_for_event() {
  local action="$1"
  local subject="$2"
  local stage="$3"
  shift 3
  refuse_untrusted_event
  local known=""
  for known in "$@"; do
    [[ "${stage}" != "${known}" ]] || break
  done
  [[ -n "${stage}" && "${stage}" == "${known}" ]] \
    || die "The stage input must be one of: $*. It is '${stage}'."
  if is_pull_request_event; then
    [[ "${GITHUB_EVENT_NAME}" == pull_request ]] \
      || die "${action} does not run on ${GITHUB_EVENT_NAME} events. Run it on pull_request events, where it checks ${subject} locally."
    [[ "${stage}" == plan ]] \
      || die "On pull request events, ${action} records only the plan stage, checked locally. Record the other stages after the merge, for example on push events."
  fi
}

# The events on which an action that deploys or closes a run may run. Each
# starts from code already in the repository: a push, a manual run, or a
# schedule.
readonly DEPLOY_EVENTS=(push workflow_dispatch schedule)

# Stops unless the job runs on one of DEPLOY_EVENTS. A pull request may only
# run a local preview, never a governed run.
require_deploy_event() {
  ! is_pull_request_event \
    || die "This action does not run on pull request events. Use the preview action instead."
  local event
  for event in "${DEPLOY_EVENTS[@]}"; do
    [[ "${GITHUB_EVENT_NAME:-}" != "${event}" ]] || return 0
  done
  die "This action runs only on push, workflow_dispatch and schedule events, not on '${GITHUB_EVENT_NAME:-}' events. Start the workflow with one of them."
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

# Escapes text for HTML in the job summary and the pull request comment, so
# text from a tool cannot change how they render or mention anyone.
html_escape() {
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  text="${text//@/&#64;}"
  printf '%s\n' "${text}"
}

# Prints FILE escaped as html_escape escapes text. One pass over the file, so
# the time grows only with the file's size.
html_escape_file() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/@/\&#64;/g' "$1"
}

# Prints one collapsible section of the job summary: TITLE, then the escaped
# text of FILE. The blank lines keep the text inside the <pre> block when it
# has blank lines of its own.
details_block() {
  local title="$1"
  local file="$2"
  echo "<details><summary>$(html_escape "${title}")</summary>"
  echo
  echo "<pre>"
  html_escape_file "${file}"
  echo "</pre>"
  echo
  echo "</details>"
}

# The most bytes of details a step's job summary may hold. GitHub drops a
# step's whole summary above 1 MiB; this leaves room for the rest.
readonly SUMMARY_DETAILS_MAX_BYTES=800000

# Appends one collapsible section to the file DETAILS: TITLE, then the escaped
# text of FILE. When the escaped section would make DETAILS too long for the
# job summary, it appends a pointer to the log instead.
append_details_block() {
  local details="$1"
  local title="$2"
  local file="$3"
  local block="${details}.block" size
  touch "${details}"
  size="$(wc -c < "${details}")"
  # Escaped text is never shorter than the file, so a file that is already too
  # long is not escaped at all.
  if [[ $((size + $(wc -c < "${file}"))) -le "${SUMMARY_DETAILS_MAX_BYTES}" ]]; then
    details_block "${title}" "${file}" > "${block}"
    if [[ $((size + $(wc -c < "${block}"))) -le "${SUMMARY_DETAILS_MAX_BYTES}" ]]; then
      cat "${block}" >> "${details}"
      rm -f "${block}"
      return 0
    fi
    rm -f "${block}"
  fi
  printf '\nThe output of %s is too long for the job summary. It is in the log.\n' "$(markdown_escape "${title}")" >> "${details}"
}

# Turns workflow commands off until resume_commands, so a line of tool output
# cannot act as a workflow command. Terraform's output and the output of the
# CLI's checks and of `run close` print with commands off. The CLI commands
# `environment detect` and `config show` print with them on: the CLI escapes
# the text they print, and masks secret values.
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
  [[ "${name}" =~ ${PORTABLE_NAME_PATTERN} ]] \
    || die "Invalid artifact name '${name}'. Use letters, digits, '.', '_' and '-'."
}

# Stops unless RETENTION_DAYS, the retention-days input, is empty or a whole
# number of days from 1.
require_retention_days() {
  [[ -z "${RETENTION_DAYS:-}" || "${RETENTION_DAYS}" =~ ^[1-9][${DIGITS}]*$ ]] \
    || die "The retention-days input must be empty or a whole number of days of 1 or more. It is '${RETENTION_DAYS}'."
}

# Prints GIVEN when it is set, and otherwise DEFAULT, the action's default
# artifact name, followed by "-attempt-" and the pipeline run's attempt
# number, so a re-run keeps the artifacts of earlier attempts. Stops unless
# the name is a valid artifact name.
artifact_name() {
  local given="$1"
  local default="$2"
  local name="${given:-${default}}"
  [[ -z "${given}" ]] || check_artifact_name "${given}"
  [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][${DIGITS}]*$ ]] \
    || die "GITHUB_RUN_ATTEMPT is missing or not a whole number. Run this action inside a GitHub Actions job."
  name+="-attempt-${GITHUB_RUN_ATTEMPT}"
  [[ "${name}" =~ ${PORTABLE_NAME_PATTERN} ]] \
    || die "The artifact name '${name}' is not a valid artifact name. Set the artifact-name input."
  # printf, because echo reads a name such as -n as one of its options.
  printf '%s\n' "${name}"
}

# Escapes text for a line of Markdown, such as a heading: HTML as html_escape
# does, then each punctuation mark Markdown reads, so the text shows as it is.
markdown_escape() {
  local text out="" char i
  local marks='\`*_{}[]()+-.!|~"'"'"'$%,/:=?^'
  # A control character, such as a line break, would end the Markdown line, so
  # it becomes a space.
  text="$(html_escape "${1//[[:cntrl:]]/ }")"
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

# Writes one step output. The value must be a single line, so it cannot add
# other outputs.
write_output() {
  local name="$1"
  local value="$2"
  [[ "${name}" =~ ^[${LOWERCASE_LETTERS}][${LOWERCASE_LETTERS}0-9-]*$ ]] || die "Invalid output name '${name}'."
  [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || die "The value of output '${name}' spans several lines."
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die "GITHUB_OUTPUT is not set. Run this action inside a GitHub Actions job."
  echo "${name}=${value}" >> "${GITHUB_OUTPUT}"
}
