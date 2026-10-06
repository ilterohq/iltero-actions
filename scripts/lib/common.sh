#!/bin/bash
#
# Helpers shared by every action. Source this file; it defines functions only.

# The folder under the runner's temporary directory where `setup` installs the
# tools. Every action finds the tools here, by absolute path.
readonly ILTERO_TOOLS_DIRNAME="iltero-tools"

# Prints an error annotation and exits with status 1.
die() {
  echo "::error::$*" >&2
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
