#!/bin/bash
#
# Closes a run with the Iltero CLI.
#
# Usage:
#   close.sh check  Refuse untrusted and pull request events; check that the job can request
#                   its identity token and run the CLI.
#   close.sh close  Close the run of this pipeline run: the change run for the stack in
#                   .iltero/config.yml and ENVIRONMENT, or the build run for APPLICATION.
#                   Exactly one of the two is set.
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
  local option
  require_one_line environment "${ENVIRONMENT:-}"
  require_one_line application "${APPLICATION:-}"
  local environment="${ENVIRONMENT:-}" application="${APPLICATION:-}"
  if [[ -n "${environment//[[:space:]]/}" && -z "${application//[[:space:]]/}" ]]; then
    option="--environment=${ENVIRONMENT}"
  elif [[ -n "${application//[[:space:]]/}" && -z "${environment//[[:space:]]/}" ]]; then
    option="--application=${APPLICATION}"
  else
    die "Give exactly one of the environment and application inputs."
  fi
  local cli
  cli="$(cli_path)"
  "${cli}" run close "${option}"
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
