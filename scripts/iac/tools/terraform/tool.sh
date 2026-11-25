#!/bin/bash
#
# The Terraform adapter: everything the infrastructure-as-code (IaC) actions
# know about Terraform. lib/tool.sh sources this file when the tool input is
# terraform, and checks that it defines the interface lib/tool.sh lists.
# Names private to this adapter start with terraform_ or TERRAFORM_. The
# functions that run Terraform need lib/guard.sh.

# The constants are read by the scripts that source this file.
# shellcheck disable=SC2034

TERRAFORM_ADAPTER_DIRECTORY="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" > /dev/null && pwd)"
readonly TERRAFORM_ADAPTER_DIRECTORY
source "${TERRAFORM_ADAPTER_DIRECTORY}/preview.sh"

# The tool's name as a person writes it, for messages and the job summary.
readonly TOOL_DISPLAY_NAME="Terraform"
# The version installed when the tool-version input is empty: the newest
# version pinned in checksums.sha256.
readonly TOOL_DEFAULT_VERSION="1.16.5"
readonly TERRAFORM_RELEASES_URL="https://releases.hashicorp.com/terraform"
readonly TERRAFORM_CHECKSUMS="${TERRAFORM_ADAPTER_DIRECTORY}/checksums.sha256"
# The folders under the home folder that Terraform reads: its local provider
# mirrors and its credentials file. Terraform gets no XDG_DATA_HOME, so it
# always uses the default data folder.
readonly TOOL_HOME_FOLDERS=(.terraform.d .local/share/terraform)
# The folder in a unit's work folder where Terraform keeps its working data.
readonly TOOL_DATA_FOLDER_NAME="terraform-data"
# The saved plan and the apply log, in a unit's work folder.
readonly TOOL_SAVED_PLAN_FILE="tfplan"
readonly TOOL_APPLY_LOG_FILE="apply.ndjson"
# The folder, in the runner's temporary folder, where Terraform keeps each
# provider it downloads, so the units of a job download each one only once.
# Terraform uses a provider from it only when the unit's lock file pins that
# provider's checksum.
readonly TERRAFORM_PLUGIN_CACHE_FOLDER_NAME="iltero-terraform-plugin-cache"
# How long init, plan, apply and each reading wait for another run's lock on
# the state to be released, before they fail.
readonly TERRAFORM_LOCK_TIMEOUT_MINUTES=5
# The variable a unit declares to read other units' state. A deploy sets it
# to true, so a unit never deploys with placeholder values in place of
# upstream state. A preview sets it to false.
readonly TERRAFORM_REMOTE_STATE_SWITCH="enable_remote_state_dependencies"

# Prints the absolute path of the Terraform binary that the action installed.
terraform_path() {
  local terraform tools
  tools="$(tools_dir)" || return 1
  terraform="${tools}/bin/terraform"
  [[ -x "${terraform}" ]] || die "Terraform is not installed."
  echo "${terraform}"
}

# Prints the pinned SHA-256 of ARCHIVE, the archive of Terraform VERSION, or
# stops if the archive is not pinned.
terraform_pinned_archive_sha256() {
  local archive="$1"
  local version="$2"
  local sha name versions=()
  [[ -f "${TERRAFORM_CHECKSUMS}" ]] || die "The pinned Terraform checksums are missing: ${TERRAFORM_CHECKSUMS}"
  # A last line with no newline at its end is read too.
  while read -r sha name || [[ -n "${sha}" ]]; do
    if [[ "${name}" == "${archive}" ]]; then
      echo "${sha}"
      return 0
    fi
    name="${name#terraform_}"
    versions+=("${name%%_*}")
  done < "${TERRAFORM_CHECKSUMS}"
  die "Terraform ${version} is not a version this action can install. It can install: $(printf '%s\n' "${versions[@]}" | sort -u | paste -sd, - | sed 's/,/, /g')."
}

# Prints the first line of what the Terraform at PATH reports as its version.
# Terraform runs with only PATH and HOME, and makes no update check.
terraform_reported_version() {
  local reported
  # The whole output is read before its first line is kept: a pipe into head
  # could stop Terraform part way and fail the step under pipefail.
  reported="$(env -i PATH="${PATH}" HOME="${HOME}" CHECKPOINT_DISABLE=1 "$1" version)" || return 1
  echo "${reported%%$'\n'*}"
}

# Installs Terraform VERSION, checked against the pinned checksums, and sets
# TOOL_INSTALLED_PATH to the path of the binary. Each run downloads the
# archive again and checks it, so only checked bytes ever run. Call it
# directly, never inside $(...), so that a refusal stops the step.
tool_install() {
  local version="$1"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Terraform version '${version}'. Use X.Y.Z."
  local platform archive sha dir terraform
  platform="$(runner_platform)" || exit 1
  archive="terraform_${version}_${platform}.zip"
  sha="$(terraform_pinned_archive_sha256 "${archive}" "${version}")" || exit 1
  dir="$(tools_dir)" || exit 1
  terraform="${dir}/bin/terraform"
  mkdir -p "${dir}/bin"
  download_checked "${TERRAFORM_RELEASES_URL}/${version}/${archive}" "${sha}" "${dir}/${archive}"
  unzip -o -q "${dir}/${archive}" terraform -d "${dir}/bin"
  rm -f "${dir}/${archive}"
  chmod 0755 "${terraform}"
  local reported
  reported="$(terraform_reported_version "${terraform}")" || die "The installed Terraform did not run."
  [[ "${reported}" == "Terraform v${version}" ]] \
    || die "The installed Terraform reports '${reported}', not 'Terraform v${version}'."
  # Read by install-tool.sh.
  TOOL_INSTALLED_PATH="${terraform}"
}

# Prints the names of the job's variables that Terraform reads as its input
# variables: TF_VAR_*.
tool_input_variable_names() {
  compgen -e | grep '^TF_VAR_' || true
}

# Prints the folder where Terraform keeps the working data of the unit whose
# work folder is WORK.
terraform_data_dir() {
  echo "$1/${TOOL_DATA_FOLDER_NAME}"
}

# Prints the NAME=VALUE pairs the CLI's state check needs to find the unit's
# Terraform working data.
tool_state_check_environment() {
  echo "TF_DATA_DIR=$(terraform_data_dir "$1")"
}

# Prepares one Terraform call for the unit whose work folder is WORK, and
# prints its NAME=VALUE pairs. A new, empty CLI configuration file for every
# call means Terraform reads no CLI configuration file from the home folder.
# It is created anew, never written through an existing file or link.
# CHECKPOINT_DISABLE turns off Terraform's version check, which would write
# into the home folder. Every call shares the job's provider cache.
terraform_prepare_call() {
  local work="$1"
  local cli_config="${work}/terraform-cli-config.tfrc" temp cache
  rm -f -- "${cli_config}" || return 1
  (set -C && : > "${cli_config}") || return 1
  temp="$(runner_temp)" || return 1
  cache="${temp}/${TERRAFORM_PLUGIN_CACHE_FOLDER_NAME}"
  # The call stops when the cache path is a link, so Terraform never writes
  # the cache through one.
  [[ ! -L "${cache}" ]] || return 1
  mkdir -p "${cache}" || return 1
  printf '%s\n' TF_IN_AUTOMATION=1 TF_INPUT=0 "TF_DATA_DIR=$(terraform_data_dir "${work}")" \
    "TF_CLI_CONFIG_FILE=${cli_config}" "TF_PLUGIN_CACHE_DIR=${cache}" CHECKPOINT_DISABLE=1
}

# Runs Terraform, under guard, for the unit whose work folder is WORK, with
# TOOL_ENVIRONMENT_PAIRS and the NAME=VALUE pairs given before "--". Returns
# Terraform's exit code.
terraform_run() {
  local work="$1"
  shift
  local pairs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    pairs+=("$1")
    shift
  done
  [[ $# -gt 0 ]] || die "terraform_run needs -- before Terraform's arguments."
  shift
  local terraform
  terraform="$(terraform_path)" || return 1
  run_guarded "${work}" terraform_prepare_call ${TOOL_ENVIRONMENT_PAIRS[@]+"${TOOL_ENVIRONMENT_PAIRS[@]}"} \
    ${pairs[@]+"${pairs[@]}"} -- "${terraform}" "$@"
}

# Prints the path of a unit's backend settings for an environment. The file
# is optional.
terraform_backend_config() {
  echo "${PWD}/$1/config/backend/$2.hcl"
}

# Prints the path of a unit's variables for an environment. The file is
# optional.
terraform_var_file() {
  echo "${PWD}/$1/config/$2.tfvars.json"
}

# Returns non-zero, with the reason on stderr, when FILE, the unit's settings
# file for ENVIRONMENT, is missing but its folder holds files matching PATTERN
# for other environments. DIR is the unit's folder. WHAT names the settings.
terraform_check_environment_file() {
  local dir="$1" environment="$2" file="$3" pattern="$4" what="$5"
  local folder
  folder="$(dirname "${file}")"
  [[ ! -f "${file}" && -d "${folder}" ]] || return 0
  # -H follows the folder when it is a link, as Terraform does. A folder that
  # cannot be read stops the check.
  local found
  found="$(find -H "${folder}" -mindepth 1 -maxdepth 1 -name "${pattern}" \( -type f -o -type l \) -print -quit)" || {
    echo "The action could not read the folder ${folder#"${PWD}/"}." >&2
    return 1
  }
  [[ -n "${found}" ]] || return 0
  echo "The unit in folder '${dir}' has ${what} for other environments but none for '${environment}': ${file#"${PWD}/"} is missing. Without it, Terraform would use only what the unit's code sets. Add the file for '${environment}'." >&2
  return 1
}

# Returns non-zero, with the reason on stderr, when the unit in DIR is not set
# up for ENVIRONMENT: it has backend settings or variables for other
# environments but not for this one, or the job sets TF_WORKSPACE. The actions
# choose where each environment's state is kept through the unit's backend
# settings file, never through a Terraform workspace.
tool_check_environment_settings() {
  local dir="$1" environment="$2" file
  if [[ -n "${TF_WORKSPACE:-}" ]]; then
    echo "The job sets TF_WORKSPACE, but the actions do not use Terraform workspaces. The unit's config/backend/<environment>.hcl file chooses where each environment's state is kept. Remove TF_WORKSPACE from the job." >&2
    return 1
  fi
  file="$(terraform_backend_config "${dir}" "${environment}")" || return 1
  terraform_check_environment_file "${dir}" "${environment}" "${file}" '*.hcl' "backend settings" || return 1
  file="$(terraform_var_file "${dir}" "${environment}")" || return 1
  terraform_check_environment_file "${dir}" "${environment}" "${file}" '*.tfvars.json' "variables"
}

# Succeeds when a unit declares the remote-state switch variable.
terraform_declares_remote_state_switch() {
  local dir="$1"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 1
  grep -qE "^[[:space:]]*variable[[:space:]]+\"${TERRAFORM_REMOTE_STATE_SWITCH}\"" "${files[@]}"
}

# Prints the name of Terraform's credentials variable for HOST, a registry
# host that check_registry_host accepted: TF_TOKEN_ followed by the host, with
# "." written "_" and "-" written "__".
tool_registry_token_variable() {
  local host="$1"
  host="${host//-/__}"
  echo "TF_TOKEN_${host//./_}"
}

# Initializes the unit in DIR for a deploy to ENVIRONMENT: its backend
# settings for the environment, and only the providers its lock file pins.
# TOKEN_PAIR, when given, is the registry token, for this call alone.
tool_deploy_init() {
  local work="$1"
  local dir="$2"
  local environment="$3"
  local token_pair="${4:-}"
  local backend_config
  local args=(-input=false -no-color -lockfile=readonly -lock-timeout="${TERRAFORM_LOCK_TIMEOUT_MINUTES}m")
  backend_config="$(terraform_backend_config "${dir}" "${environment}")" || return 1
  [[ ! -f "${backend_config}" ]] || args+=(-backend-config="${backend_config}")
  (
    cd "${dir}" || exit 1
    terraform_run "${work}" ${token_pair:+"${token_pair}"} -- init "${args[@]}"
  )
}

# Writes the variables files arguments of the unit in DIR for ENVIRONMENT to
# WORK/variable-args, one per line, so the deploy's second plan and readings
# use the same variables.
terraform_write_variable_args() {
  local work="$1"
  local dir="$2"
  local environment="$3"
  local var_file
  var_file="$(terraform_var_file "${dir}" "${environment}")" || return 1
  : > "${work}/variable-args" || return 1
  [[ ! -f "${var_file}" ]] || echo "-var-file=${var_file}" >> "${work}/variable-args"
  if terraform_declares_remote_state_switch "${dir}"; then
    # Set from a variables file, not -var: Terraform records a -var value in
    # the plan as a string. The file comes last, so it wins.
    echo "${TERRAFORM_REMOTE_STATE_SWITCH} = true" > "${work}/with-upstream.tfvars" || return 1
    echo "-var-file=${work}/with-upstream.tfvars" >> "${work}/variable-args"
  fi
}

# Plans the unit in DIR for a deploy to ENVIRONMENT. Writes the saved plan
# WORK/TOOL_SAVED_PLAN_FILE and its JSON, WORK/plan.json.
tool_deploy_plan() {
  local work="$1"
  local dir="$2"
  local environment="$3"
  terraform_write_variable_args "${work}" "${dir}" "${environment}" || return 1
  terraform_plan_to_json "${work}" "${dir}" "${work}/${TOOL_SAVED_PLAN_FILE}" "${work}/plan.json"
}

# Applies the saved plan of the unit in DIR, and writes Terraform's JSON log
# of the apply to WORK/TOOL_APPLY_LOG_FILE. Then prints the log's messages,
# whether the apply succeeded or failed. Returns Terraform's exit code.
tool_apply() {
  local work="$1"
  local dir="$2"
  local log="${work}/${TOOL_APPLY_LOG_FILE}" status=0
  (
    cd "${dir}" || exit 1
    terraform_run "${work}" -- apply -input=false -json -lock-timeout="${TERRAFORM_LOCK_TIMEOUT_MINUTES}m" \
      "${work}/${TOOL_SAVED_PLAN_FILE}" > "${log}"
  ) || status=$?
  terraform_print_apply_log "${log}" || echo "The action could not show the apply's messages."
  return "${status}"
}

# Prints the message of each entry in Terraform's JSON log FILE, and the
# detail of each error or warning. A line that is not a log entry is printed
# as it is.
terraform_print_apply_log() {
  [[ -f "$1" ]] || return 0
  "$(tools_dir)/venv/bin/python" -I -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
with open(sys.argv[1], encoding="utf-8", errors="replace") as log:
    for line in log:
        line = line.rstrip("\n")
        try:
            entry = json.loads(line)
        except (ValueError, RecursionError):
            entry = None
        if not isinstance(entry, dict):
            print(line)
            continue
        message = entry.get("@message")
        if isinstance(message, str) and message:
            print(message)
        diagnostic = entry.get("diagnostic")
        detail = diagnostic.get("detail") if isinstance(diagnostic, dict) else None
        if isinstance(detail, str) and detail:
            print(detail)
' "$1"
}

# Writes the state of the unit in DIR, as JSON, to WORK/state.json.
tool_read_state() {
  local work="$1"
  local dir="$2"
  (
    cd "${dir}" || exit 1
    terraform_run "${work}" -- show -json > "${work}/state.json"
  )
}

# Plans the unit in DIR into FILE, as JSON, with its saved plan's input
# variables and the Terraform options OPTIONS: saved as SAVED in the unit's
# work folder WORK, then shown. A plan Terraform did not finish is not kept.
terraform_plan_to_json() {
  local work="$1"
  local dir="$2"
  local saved="$3"
  local file="$4"
  shift 4
  local status=0
  local variable_args=()
  mapfile -t variable_args < "${work}/variable-args" || return 1
  (
    cd "${dir}" || exit 1
    terraform_run "${work}" -- plan -input=false -no-color "$@" \
      -lock-timeout="${TERRAFORM_LOCK_TIMEOUT_MINUTES}m" -out="${saved}" ${variable_args[@]+"${variable_args[@]}"} \
      && terraform_run "${work}" -- show -json "${saved}" > "${file}"
  ) || status=$?
  [[ "${status}" -eq 0 ]] || rm -f "${file}"
  return "${status}"
}

# Takes a reading of the deployed resources of the unit in DIR into FILE, as
# JSON: a refresh-only plan, saved in the unit's work folder WORK and never
# applied. Applying it would write what it read into the state, so drift would
# no longer show. A reading Terraform did not finish is not kept.
tool_take_reading() {
  local work="$1"
  local dir="$2"
  local file="$3"
  terraform_plan_to_json "${work}" "${dir}" "${work}/reading-$(basename "${file%.json}").tfplan" "${file}" -refresh-only
}

# Plans the change of the unit in DIR again, against the current state, with
# the input variables of its saved plan, and writes the new plan to FILE, as
# JSON. The new plan is saved in the unit's work folder WORK apart from the
# saved plan, and is never applied: only the saved plan is.
tool_replan() {
  local work="$1"
  local dir="$2"
  local file="$3"
  terraform_plan_to_json "${work}" "${dir}" "${work}/replan.tfplan" "${file}"
}
