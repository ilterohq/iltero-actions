#!/bin/bash
#
# Opens and closes a governed run with the Iltero CLI.
#
# Usage:
#   run.sh check                          Refuse untrusted and pull request events; check the job can run the CLI.
#   run.sh open ENVIRONMENT               Open a run from its plan stage, for the stack in .iltero/config.yml.
#                                         The CLI writes run_id and run_settings_digest.
#   run.sh close RUN_ID                   Close the run.
#
# The CLI's exit code is the step's exit code.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"

# The first stage a run checks. The deploy job starts with the plan.
readonly FIRST_STAGE="plan"

cmd_check() {
  refuse_untrusted_event
  refuse_pull_request
  require_id_token
  cli_path > /dev/null
}

cmd_open() {
  local environment="$1"
  local cli linked
  cli="$(cli_path)"
  linked="$(project_linked)"
  [[ "${linked}" == true ]] \
    || die "This project has no platform section in .iltero/config.yml, so it has no governed run to open."
  "${cli}" run open --stage="${FIRST_STAGE}" --environment="${environment}"
}

cmd_close() {
  local run_id="$1"
  local cli
  cli="$(cli_path)"
  "${cli}" run close --run-id="${run_id}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    open) [[ $# -eq 1 ]] || die "Usage: run.sh open ENVIRONMENT"; cmd_open "$@" ;;
    close) [[ $# -eq 1 ]] || die "Usage: run.sh close RUN_ID"; cmd_close "$@" ;;
    *) die "Unknown command '${command}'. Use: check | open ENVIRONMENT | close RUN_ID" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
