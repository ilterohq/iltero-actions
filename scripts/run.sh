#!/bin/bash
#
# Closes a run with the Iltero CLI.
#
# Usage:
#   run.sh check                Refuse untrusted and pull request events; check the job can run the CLI.
#   run.sh close ENVIRONMENT    Close the run of the pipeline run for the stack in .iltero/config.yml
#                               and ENVIRONMENT.
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
  local environment="$1"
  local cli
  cli="$(cli_path)"
  "${cli}" run close --environment="${environment}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    close) [[ $# -eq 1 ]] || die "Usage: run.sh close ENVIRONMENT"; cmd_close "$@" ;;
    *) die "Unknown command '${command}'. Use: check | close ENVIRONMENT" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
