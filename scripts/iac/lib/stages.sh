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

# The exit codes of `iltero record in-scope`: the stage is in the record's
# scope, or out of it. Every other code is an error.
readonly IN_SCOPE_STATUS=0
readonly OUT_OF_SCOPE_STATUS=3
# The exit code of `iltero record in-scope` for a record that does not verify.
readonly RECORD_DOES_NOT_VERIFY_STATUS=9

# Prints "true" when STAGE is in the scope of the record of UNIT in OUT, and
# "false" when it is not, as the CLI answers. Keeps the CLI's answer in
# WORK/in-scope-STAGE.txt, and shows it on stderr with workflow commands
# paused, so only "true" or "false" is printed on stdout. Exits with the CLI's
# own code on any other answer.
record_expects_stage() {
  local work="$1"
  local out="$2"
  local unit="$3"
  local stage="$4"
  local status=0
  run_cli_logged "${work}/in-scope-${stage}.txt" record in-scope "${out}/units/${unit}" --stage="${stage}" >&2 \
    || status=$?
  case "${status}" in
    "${IN_SCOPE_STATUS}") echo true ;;
    "${OUT_OF_SCOPE_STATUS}") echo false ;;
    *) exit_with_error "${status}" "The CLI could not say whether the record of unit '${unit}' expects the ${stage//_/-} stage (exit ${status})." ;;
  esac
}

# Prints the summary cell for a record whose scope the CLI could not give,
# from the CLI's exit code STATUS.
record_scope_failure() {
  local status="$1"
  if [[ "${status}" -eq "${RECORD_DOES_NOT_VERIFY_STATUS}" ]]; then
    echo "record does not verify"
  else
    echo "record unreadable"
  fi
}

# Prints the summary cell for the pre-deploy stage of UNIT in a project with
# no platform section, which does not run it: "not in scope" when its record
# in OUT does not expect the stage, and "not run" when it does, with a warning
# that says how to leave the stage out. Keeps the CLI's answer in WORK.
# Returns 1 when OUT holds no record of the unit, and the CLI's own code when
# it could not give the record's scope.
local_pre_deploy_result() {
  local work="$1"
  local out="$2"
  local unit="$3"
  local expects status=0
  if [[ ! -f "${out}/units/${unit}/car.json" ]]; then
    echo "::error::The records directory holds no record of unit '${unit}'." >&2
    return 1
  fi
  expects="$(record_expects_stage "${work}" "${out}" "${unit}" pre_deploy)" || status=$?
  [[ "${status}" -eq 0 ]] || return "${status}"
  if [[ "${expects}" == true ]]; then
    echo "::warning::The record of unit '${unit}' expects the pre-deploy stage, which a project with no platform section does not run. List pre_deploy under stages.out_of_scope in .iltero/config.yml." >&2
    echo "not run"
  else
    echo "not in scope"
  fi
}

# Runs the CLI's state check, which refuses a unit that keeps its Terraform
# state in its working directory DIR, where the state is lost with the
# runner. The CLI reads TF_DATA_DIR from the environment. Returns the CLI's
# exit code.
state_check() {
  local dir="$1"
  local work="$2"
  run_cli_logged "${work}/state-check.txt" state check --working-directory="${dir}"
}
