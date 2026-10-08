#!/bin/bash
#
# Opens and closes a governed run with the Iltero CLI.
#
# Usage:
#   run.sh check                          Refuse untrusted and pull request events; check the job can run the CLI.
#   run.sh open STACK_ID ENVIRONMENT      Open a run from its plan stage. The CLI writes run_id and pins_digest.
#   run.sh close RUN_ID                   Close the run.
#
# The CLI's exit code is the step's exit code.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The first stage a run checks. The deploy job starts with the plan.
readonly FIRST_STAGE="plan"

cmd_check() {
  refuse_untrusted_event
  refuse_pull_request
  require_id_token
  cli_path > /dev/null
}

cmd_open() {
  local stack_id="$1"
  local environment="$2"
  local cli
  cli="$(cli_path)"
  "${cli}" cloud run open --stage="${FIRST_STAGE}" --stack-id="${stack_id}" --environment="${environment}"
}

cmd_close() {
  local run_id="$1"
  local cli
  cli="$(cli_path)"
  "${cli}" cloud run close --run-id="${run_id}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    open) [[ $# -eq 2 ]] || die "Usage: run.sh open STACK_ID ENVIRONMENT"; cmd_open "$@" ;;
    close) [[ $# -eq 1 ]] || die "Usage: run.sh close RUN_ID"; cmd_close "$@" ;;
    *) die "Unknown command '${command}'. Use: check | open STACK_ID ENVIRONMENT | close RUN_ID" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
