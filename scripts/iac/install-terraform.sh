#!/bin/bash
#
# Installs the pinned Terraform that the deploy and preview actions run.
#
# Usage:
#   iac/install-terraform.sh VERSION   Install Terraform VERSION, checked against the pinned
#                                      checksums in terraform.sha256, next to this script.
#
# Each run downloads the archive again and checks it, so only checked bytes
# ever run.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/install.sh"

readonly TERRAFORM_RELEASES_URL="https://releases.hashicorp.com/terraform"
TERRAFORM_CHECKSUMS="$(dirname "${BASH_SOURCE[0]}")/terraform.sha256"
readonly TERRAFORM_CHECKSUMS

# Prints the pinned SHA-256 of a Terraform archive, or stops if the archive is
# not pinned.
pinned_terraform_sha256() {
  local archive="$1"
  local sha name
  [[ -f "${TERRAFORM_CHECKSUMS}" ]] || die "The pinned Terraform checksums are missing: ${TERRAFORM_CHECKSUMS}"
  while read -r sha name; do
    if [[ "${name}" == "${archive}" ]]; then
      echo "${sha}"
      return 0
    fi
  done < "${TERRAFORM_CHECKSUMS}"
  die "Terraform archive '${archive}' is not pinned. Pinned archives: $(cut -d' ' -f3 "${TERRAFORM_CHECKSUMS}" | tr '\n' ' ')"
}

# Prints the first line of what the Terraform at PATH reports as its version.
# Terraform runs with only PATH and HOME, and makes no update check.
reported_version() {
  local reported
  # The whole output is read before its first line is kept: a pipe into head
  # could stop Terraform part way and fail the step under pipefail.
  reported="$(env -i PATH="${PATH}" HOME="${HOME}" CHECKPOINT_DISABLE=1 "$1" version)" || return 1
  echo "${reported%%$'\n'*}"
}

main() {
  [[ $# -eq 1 ]] || die "Usage: iac/install-terraform.sh VERSION"
  local version="$1"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Terraform version '${version}'. Use X.Y.Z."

  local platform archive sha dir terraform
  platform="$(runner_platform)"
  archive="terraform_${version}_${platform}.zip"
  sha="$(pinned_terraform_sha256 "${archive}")"
  dir="$(tools_dir)"
  terraform="${dir}/bin/terraform"
  mkdir -p "${dir}/bin"

  download_checked "${TERRAFORM_RELEASES_URL}/${version}/${archive}" "${sha}" "${dir}/${archive}"
  unzip -o -q "${dir}/${archive}" terraform -d "${dir}/bin"
  rm -f "${dir}/${archive}"
  chmod 0755 "${terraform}"

  local reported
  reported="$(reported_version "${terraform}")" || die "The installed Terraform did not run."
  [[ "${reported}" == "Terraform v${version}" ]] \
    || die "The installed Terraform reports '${reported}', not 'Terraform v${version}'."
  write_output terraform-version "${version}"
  write_output terraform-path "${terraform}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
