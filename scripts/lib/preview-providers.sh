#!/bin/bash
#
# Lets a unit be planned with no cloud credentials. For each provider a unit
# configures, an adapter adds settings that skip every credential check, and
# mock credentials. Add a cloud by adding a function named
# preview_provider_<name> that takes the unit directory, prints its override
# block and appends to PREVIEW_PROVIDER_ENV.

# Environment variables the adapters set for Terraform, as NAME=value.
PREVIEW_PROVIDER_ENV=()

preview_provider_aws() {
  local dir="$1"
  local assume_role=""
  # An empty assume_role block replaces the unit's own, so no role is assumed.
  # It is added only when the unit assumes a role.
  if grep -qE '^[[:space:]]*assume_role[[:space:]]*\{' "${dir}"/*.tf; then
    assume_role="  assume_role {}"
  fi
  cat << HCL
provider "aws" {
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
${assume_role}
}
HCL
  PREVIEW_PROVIDER_ENV+=(
    AWS_ACCESS_KEY_ID=iltero-preview-mock
    AWS_SECRET_ACCESS_KEY=iltero-preview-mock
    AWS_EC2_METADATA_DISABLED=true
    AWS_REGION=us-east-1
  )
}

# Prints the names of the providers a unit configures in its own files.
configured_providers() {
  local dir="$1"
  local files=("${dir}"/*.tf)
  [[ -e "${files[0]}" ]] || return 0
  grep -hoE '^[[:space:]]*provider[[:space:]]+"[^"]+"' "${files[@]}" | sed -E 's/.*"([^"]+)"/\1/' | sort -u
}

# Prints the override file for a unit: a local backend, so planning reads and
# writes no remote state, and each provider's adapter block. Fails when a
# provider has no adapter.
preview_override() {
  local dir="$1"
  local provider
  PREVIEW_PROVIDER_ENV=()
  cat << 'HCL'
terraform {
  backend "local" {}
}
HCL
  while IFS= read -r provider; do
    [[ -n "${provider}" ]] || continue
    if ! declare -F "preview_provider_${provider}" > /dev/null; then
      echo "No preview adapter for provider '${provider}'." >&2
      return 1
    fi
    "preview_provider_${provider}" "${dir}"
  done < <(configured_providers "${dir}")
}
