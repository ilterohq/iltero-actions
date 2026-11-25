#!/bin/bash
#
# The CLI's checks of a unit's infrastructure as code (IaC) change, shared by
# the deploy, preview and record-iac actions. Source this file after
# common.sh and cli-stages.sh.

# Runs one stage of the CLI's check of a unit's IaC change. See
# check_change_stage.
check_stage() {
  check_change_stage iac "$@"
}

# Prints the summary words for the post-deploy stage: "passed" or "failed",
# as check_result prints for the CLI's exit code STATUS, followed by "without
# the state file" when SHOW_STATUS, the code of the tool's reading of the
# state after the apply, is not 0.
post_deploy_result() {
  local status="$1"
  local show_status="$2"
  local result
  result="$(check_result "${status}")"
  [[ "${show_status}" == 0 ]] || result+=" without the state file"
  echo "${result}"
}

# The summary cell for a unit whose record requires the pre-deploy stage in a
# project not linked to the server, where the stage cannot run.
readonly PRE_DEPLOY_CANNOT_RUN_RESULT="required, needs the server"

# Prints the summary cell for the pre-deploy stage of UNIT in a project not
# linked to the server. Such a project cannot run the stage. Keeps the CLI's
# answer in WORK.
#   - The record in OUT does not require the stage: prints "not required".
#   - The record requires it: prints PRE_DEPLOY_CANNOT_RUN_RESULT and an
#     error, and returns 1.
#   - OUT holds no record of the unit: prints nothing and returns 1.
#   - The CLI could not give the record's scope: prints nothing and returns
#     the CLI's own code.
# Callers tell the failures apart by the printed cell.
local_pre_deploy_result() {
  local work="$1"
  local out="$2"
  local unit="$3"
  local required status=0
  if [[ ! -f "${out}/units/${unit}/car.json" ]]; then
    echo "::error::The records directory holds no record of unit '${unit}'." >&2
    return 1
  fi
  required="$(record_requires_stage "${work}" "${out}" "${unit}" pre_deploy)" || status=$?
  [[ "${status}" -eq 0 ]] || return "${status}"
  if [[ "${required}" == true ]]; then
    echo "::error::The record of unit '${unit}' requires the pre-deploy stage, which only a project linked to the server can run." >&2
    echo "${PRE_DEPLOY_CANNOT_RUN_RESULT}"
    return 1
  fi
  echo "not required"
}

# Prints the job summary's title for the CLI's output in the file STEP.txt of
# a unit's work folder: a stage, the state check, or the CLI's answer to
# whether the record requires a stage.
details_title() {
  local step="$1"
  local stage
  case "${step}" in
    state-check) echo "state check" ;;
    in-scope-*)
      stage="${step#in-scope-}"
      echo "is the ${stage//_/-} stage required?"
      ;;
    *) echo "${step//_/-}" ;;
  esac
}

# Runs the CLI's state check, which refuses a unit that keeps its state in
# its working directory DIR, where the state is lost with the runner. The
# caller exports the variables the tool's adapter gives for it. Returns the
# CLI's exit code.
state_check() {
  local dir="$1"
  local work="$2"
  run_cli_logged "${work}/state-check.txt" state check --working-directory="${dir}"
}
