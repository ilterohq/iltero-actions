#!/bin/bash
#
# The Terraform adapter's preview: plans a unit with no cloud credentials.
# For each provider a unit configures, a function prints Terraform settings
# that skip every credential check. Every cloud's mock credentials
# (clouds/<cloud>.sh) are always set, even for a provider that only a module
# configures, so Terraform never looks for real ones. Add a Terraform
# provider by adding a function named terraform_preview_provider_<name>. It
# takes the unit directory, and prints an override block for each block of that
# provider in the unit, aliased blocks included. Sourced by tool.sh.

# The override file the action adds to a unit while it plans it.
readonly TERRAFORM_OVERRIDE_FILE="zzz_iltero_preview_override.tf"
# The form of an alias the override file can name: a letter or underscore,
# then letters, digits, underscores and dashes. Terraform's names take the
# same form.
readonly TERRAFORM_PROVIDER_ALIAS_PATTERN='^[A-Za-z_][A-Za-z0-9_-]*$'

terraform_preview_provider_aws() {
  local dir="$1"
  local alias assumes_role
  while read -r assumes_role alias; do
    [[ -z "${alias}" || "${alias}" =~ ${TERRAFORM_PROVIDER_ALIAS_PATTERN} ]] || {
      echo "The preview cannot plan an AWS provider block whose alias is not a plain name." >&2
      return 1
    }
    echo 'provider "aws" {'
    [[ -z "${alias}" ]] || echo "  alias = \"${alias}\""
    echo '  skip_credentials_validation = true'
    echo '  skip_requesting_account_id  = true'
    echo '  skip_metadata_api_check     = true'
    # An empty assume_role block replaces the block's own, so no role is
    # assumed. It is added only to a block that assumes a role.
    [[ "${assumes_role}" != true ]] || echo '  assume_role {}'
    echo '}'
  done < <(terraform_provider_blocks "${dir}" aws)
}

# Prints one line for each block of provider NAME in the .tf files of the unit
# in DIR. The line starts with true when the block assumes a role, and false
# when it does not. A space and the block's alias follow. The default block has
# no alias, so its line ends after the space.
terraform_provider_blocks() {
  local dir="$1" name="$2"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 0
  # The parser skips lines that hold only a comment. It reads each provider
  # block within one file, so a block never runs on into the next file.
  awk -v name="${name}" '
    FNR == 1 { inside = 0 }
    /^[[:space:]]*(#|\/\/)/ { next }
    !inside && $0 ~ "^[[:space:]]*provider[[:space:]]+\"" name "\"[[:space:]]*[{]" {
      inside = 1; depth = 0; alias = ""; role = "false"
    }
    inside {
      line = $0
      # The alias is read only at the top level of the block: on a line of
      # its own, or right after the opening brace of the block.
      if ((depth == 1 && match(line, /^[[:space:]]*alias[[:space:]]*=[[:space:]]*"[^"]+"/)) ||
          (depth == 0 && match(line, /[{][[:space:]]*alias[[:space:]]*=[[:space:]]*"[^"]+"/))) {
        found = substr(line, RSTART, RLENGTH)
        sub(/^[^"]*"/, "", found)
        sub(/"$/, "", found)
        alias = found
      }
      if (line ~ /(^|[[:space:]{])assume_role[[:space:]]*[{]/) role = "true"
      depth += gsub(/[{]/, "{", line) - gsub(/[}]/, "}", line)
      if (depth <= 0) { print role " " alias; inside = 0 }
    }
  ' "${files[@]}"
}

# Prints the providers the preview supports, separated by commas.
terraform_supported_preview_providers() {
  declare -F | sed -n 's/^declare -f terraform_preview_provider_\([a-z0-9_]*\)$/\1/p' | paste -sd, - | sed 's/,/, /g'
}

# Prints the names of the providers a unit configures in its own files.
terraform_configured_providers() {
  local dir="$1"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 0
  grep -hoE '^[[:space:]]*provider[[:space:]]+"[^"]+"' "${files[@]}" | sed -E 's/.*"([^"]+)"/\1/' | sort -u
}

# Prints the override file for a unit: a local backend, so planning reads and
# writes no remote state, and each provider's adapter block. Fails when a
# provider has no adapter.
terraform_preview_override() {
  local dir="$1"
  local provider
  cat << 'HCL'
terraform {
  backend "local" {}
}
HCL
  while IFS= read -r provider; do
    [[ -n "${provider}" ]] || continue
    if ! declare -F "terraform_preview_provider_${provider}" > /dev/null; then
      echo "The preview cannot plan provider '${provider}' without credentials. It supports: $(terraform_supported_preview_providers)." >&2
      return 1
    fi
    "terraform_preview_provider_${provider}" "${dir}" || return 1
  done < <(terraform_configured_providers "${dir}")
}

# Plans the unit in DIR with no credentials, for ENVIRONMENT. Writes the saved
# plan and plan.json under WORK. TOKEN_PAIR, when given, is the registry
# token, for the init call alone. Sets PLANNED_WITHOUT_UPSTREAM to true when
# the remote-state switch was off. Returns non-zero, with the reason on
# stderr, when the unit cannot be planned.
tool_preview_plan() {
  local work="$1"
  local dir="$2"
  local environment="$3"
  local token_pair="${4:-}"
  local override="${dir}/${TERRAFORM_OVERRIDE_FILE}" var_file
  var_file="$(terraform_var_file "${dir}" "${environment}")" || return 1

  # A link counts, even one to nothing, so the copy below never follows one.
  [[ ! -e "${override}" && ! -L "${override}" ]] || {
    echo "The preview adds a file named ${TERRAFORM_OVERRIDE_FILE} to each unit, and this unit already has one. Rename the unit's file." >&2
    return 1
  }
  terraform_preview_override "${dir}" > "${work}/override.tf" || return 1
  cp "${work}/override.tf" "${override}" || return 1

  local args=(-input=false -refresh=false -lock=false -out="${work}/${TOOL_SAVED_PLAN_FILE}")
  [[ ! -f "${var_file}" ]] || args+=(-var-file="${var_file}")
  PLANNED_WITHOUT_UPSTREAM=false
  if terraform_declares_remote_state_switch "${dir}"; then
    # Set from a variables file, not -var: Terraform records a -var value in
    # the plan as a string, and a file value as its own type. The file comes
    # last, so it wins over the unit's variables file.
    echo "${TERRAFORM_REMOTE_STATE_SWITCH} = false" > "${work}/without-upstream.tfvars" || return 1
    args+=(-var-file="${work}/without-upstream.tfvars")
    # Read by preview.sh.
    # shellcheck disable=SC2034
    PLANNED_WITHOUT_UPSTREAM=true
  fi

  # Terraform reads the unit's committed lock file and never writes one, as in
  # a deploy. A unit that the deploy would refuse is then refused here too.
  local init_args=(-input=false -no-color -lockfile=readonly)

  local status=0
  (
    cd "${dir}" || exit 1
    terraform_run "${work}" ${token_pair:+"${token_pair}"} -- init "${init_args[@]}" > "${work}/terraform.log" 2>&1 \
      && terraform_run "${work}" -- plan -no-color "${args[@]}" >> "${work}/terraform.log" 2>&1 \
      && terraform_run "${work}" -- show -json "${work}/${TOOL_SAVED_PLAN_FILE}" > "${work}/plan.json" 2>> "${work}/terraform.log"
  ) || status=$?
  # The override file is removed, and the log is shown, whatever failed first.
  local cleanup_status=0
  rm -f "${override}" || cleanup_status=1
  if [[ "${status}" -ne 0 ]]; then
    cat "${work}/terraform.log" >&2
    echo "Terraform could not plan the unit. Its output is above." >&2
    return 1
  fi
  [[ "${cleanup_status}" -eq 0 ]] \
    || { echo "The preview could not remove the file it added to the unit." >&2; return 1; }
}
