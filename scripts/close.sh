#!/bin/bash
#
# Closes a run with the Iltero CLI.
#
# Usage:
#   close.sh check  Refuse untrusted and pull request events; check that the job can request
#                   its identity token and run the CLI.
#   close.sh close  Close the run of this pipeline run: the change run for the stack in
#                   .iltero/config.yml and ENVIRONMENT, the build run for APPLICATION, or,
#                   with both set, the image deploy run for APPLICATION and ENVIRONMENT.
#
# The CLI's exit code is the step's exit code.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

cmd_check() {
  refuse_untrusted_event
  refuse_pull_request
  require_id_token
  cli_path > /dev/null
}

cmd_close() {
  require_one_line environment "${ENVIRONMENT:-}"
  require_one_line application "${APPLICATION:-}"
  local environment="${ENVIRONMENT:-}" application="${APPLICATION:-}"
  local options=()
  [[ -z "${application//[[:space:]]/}" ]] || options+=("--application=${APPLICATION}")
  [[ -z "${environment//[[:space:]]/}" ]] || options+=("--environment=${ENVIRONMENT}")
  [[ ${#options[@]} -gt 0 ]] || die "Give the environment input, the application input, or both."
  local cli
  cli="$(cli_path)"
  "${cli}" run close "${options[@]}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    close) [[ $# -eq 0 ]] || die "Usage: close.sh close"; cmd_close ;;
    *) die "Unknown command '${command}'. Use: check | close" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
