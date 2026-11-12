#!/bin/bash
#
# The CLI's check of one stage of a change, used for both infrastructure as
# code (IaC) changes and container images. Source this file after common.sh.

# Runs the CLI with ARGS, using the evaluator that `setup` installed. Prints its
# output with workflow commands paused and keeps a copy in LOG for the summary.
# Returns the CLI's exit code.
run_cli_logged() {
  local log="$1"
  shift
  local cli tools status=0
  # Each lookup returns on failure itself: callers may run this where bash
  # ignores set -e.
  cli="$(cli_path)" || return 1
  tools="$(tools_dir)" || return 1
  ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" "$@" > "${log}" 2>&1 || status=$?
  print_untrusted "${log}"
  return "${status}"
}

# Runs one stage of the CLI's check of a KIND of change (iac or image), with
# the CLI's remaining arguments. Prints its output and keeps a copy in
# WORK/STAGE.txt. Returns the CLI's exit code.
check_change_stage() {
  local kind="$1"
  local work="$2"
  local stage="$3"
  shift 3
  run_cli_logged "${work}/${stage}.txt" "${kind}" check --stage="${stage}" "$@"
}
