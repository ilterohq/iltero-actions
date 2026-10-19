#!/bin/bash
#
# Runs Terraform with a scrubbed environment, and reads what a unit declares.
# Source this file after common.sh.

# The variable a unit declares to read other units' state. A deploy sets it
# to true, so a placeholder can never be deployed; a preview sets it to false.
readonly REMOTE_STATE_SWITCH="enable_remote_state_dependencies"

# Prints the folder where Terraform keeps a unit's working data.
terraform_data_dir() {
  echo "$1/terraform-data"
}

# Succeeds when a unit declares the remote-state switch variable.
declares_remote_state_switch() {
  local dir="$1"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 1
  grep -qE "^[[:space:]]*variable[[:space:]]+\"${REMOTE_STATE_SWITCH}\"" "${files[@]}"
}

# The variables run_terraform always gives Terraform.
readonly TERRAFORM_BASE_ENV=(PATH HOME TF_IN_AUTOMATION TF_INPUT TF_DATA_DIR)

# Runs Terraform for the unit whose work folder is WORK. Its environment holds
# only PATH, HOME, Terraform's automation settings and the NAME=VALUE pairs
# given before "--", and nothing else from the job's environment. The pairs
# are exported in a subshell, and the CLI's Python starts Terraform with only
# those names, so no value is passed on a command line.
run_terraform() {
  local work="$1"
  shift
  local pairs=() names=("${TERRAFORM_BASE_ENV[@]}")
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "run_terraform takes NAME=VALUE pairs before --."
    pairs+=("$1")
    names+=("${1%%=*}")
    shift
  done
  [[ $# -gt 0 ]] || die "run_terraform needs -- before Terraform's arguments."
  shift
  [[ -n "${HOME:-}" ]] || die "HOME is not set."
  local terraform data_dir
  terraform="$(terraform_path)"
  data_dir="$(terraform_data_dir "${work}")"
  (
    local pair
    export TF_IN_AUTOMATION=1 TF_INPUT=0 TF_DATA_DIR="${data_dir}"
    for pair in ${pairs[@]+"${pairs[@]}"}; do
      export "${pair?}"
    done
    exec "$(tools_dir)/venv/bin/python" -I -c '
import os, sys
count = int(sys.argv[1])
names, command = sys.argv[2:2 + count], sys.argv[2 + count:]
os.execve(command[0], command, {name: os.environ[name] for name in names if name in os.environ})
' "${#names[@]}" "${names[@]}" "${terraform}" "$@"
  )
}
