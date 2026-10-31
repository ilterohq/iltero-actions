#!/bin/bash
#
# The CLI's checks of a unit, shared by the deploy, preview and record-iac
# actions. Source this file after common.sh.

# Runs one CLI stage for a unit, with the CLI's remaining arguments. Prints
# its output and keeps a copy in WORK/STAGE.txt for the summary. Returns the
# CLI's exit code.
check_stage() {
  local work="$1"
  local stage="$2"
  shift 2
  local cli tools status=0
  cli="$(cli_path)"
  tools="$(tools_dir)"
  ILTERO_OPA_PATH="${tools}/bin/opa" "${cli}" iac check --stage="${stage}" "$@" \
    > "${work}/${stage}.txt" 2>&1 || status=$?
  print_untrusted "${work}/${stage}.txt"
  return "${status}"
}

# Prints "true" when the record of UNIT in OUT expects STAGE, and "false"
# when it does not. The CLI writes the stages a record expects at the plan
# stage, from the run's settings or the project's configuration. Stops when
# the record cannot be read.
record_expects_stage() {
  local out="$1"
  local unit="$2"
  local stage="$3"
  "$(tools_dir)/venv/bin/python" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as record:
    stages = json.load(record).get("expected_stages")
if not isinstance(stages, list):
    sys.exit("the record has no expected_stages field")
print("true" if sys.argv[2] in stages else "false")
' "${out}/units/${unit}/car.json" "${stage}" || die "The CLI's record of unit '${unit}' could not be read."
}

# Runs the CLI's state check, which refuses a unit that keeps its Terraform
# state in its working directory DIR, where the state is lost with the
# runner. The CLI reads TF_DATA_DIR from the environment. Returns the CLI's
# exit code.
state_check() {
  local dir="$1"
  local work="$2"
  local status=0
  "$(cli_path)" state check --working-directory="${dir}" > "${work}/state-check.txt" 2>&1 || status=$?
  print_untrusted "${work}/state-check.txt"
  return "${status}"
}
