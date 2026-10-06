#!/bin/bash
#
# Installs the tools the other actions use: Terraform and the Iltero CLI.
#
# Usage:
#   setup.sh check                Refuse untrusted events and unsupported runners.
#   setup.sh terraform VERSION    Install Terraform VERSION, checked against the pinned checksums.
#   setup.sh cli                  Install the Iltero CLI and its evaluator at the pinned versions.
#
# GITHUB_ACTION_PATH is the `setup/` folder. It holds the pins:
#   terraform.sha256          SHA-256 of each pinned Terraform archive.
#   cli-sources.txt           The commits of iltero-schemas and iltero-cli to install.
#   cli-requirements.txt      Every other package the CLI needs, with hashes.
#                             Written by scripts/lock-cli.py.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

readonly TERRAFORM_RELEASES_URL="https://releases.hashicorp.com/terraform"
readonly OPA_RELEASES_URL="https://github.com/open-policy-agent/opa/releases/download"
readonly GITHUB_URL="https://github.com"
readonly CURL_OPTIONS=(-fsSL --proto "=https" --tlsv1.2 --retry 3 --retry-all-errors --retry-delay 2)

# Downloads a file and keeps it only if its SHA-256 matches the pinned value.
download_checked() {
  local url="$1"
  local sha="$2"
  local destination="$3"
  local partial="${destination}.part"
  curl "${CURL_OPTIONS[@]}" -o "${partial}" "${url}" || die "Download failed: ${url}"
  if ! echo "${sha}  ${partial}" | sha256sum -c --quiet - > /dev/null 2>&1; then
    rm -f "${partial}"
    die "The download from ${url} does not match its pinned checksum."
  fi
  mv "${partial}" "${destination}"
}

# Prints the Terraform platform name of this runner, or stops on an
# unsupported runner. Only Linux runners on x64 or ARM64 are supported.
runner_platform() {
  [[ "${RUNNER_OS:-}" == "Linux" ]] || die "Unsupported runner OS '${RUNNER_OS:-}'. Use a Linux runner."
  case "${RUNNER_ARCH:-}" in
    X64) echo "linux_amd64" ;;
    ARM64) echo "linux_arm64" ;;
    *) die "Unsupported runner architecture '${RUNNER_ARCH:-}'. Use an X64 or ARM64 runner." ;;
  esac
}

cmd_check() {
  refuse_untrusted_event
  runner_platform > /dev/null
}

# Prints the pinned SHA-256 of a Terraform archive, or stops if the archive is
# not pinned.
pinned_terraform_sha256() {
  local archive="$1"
  local sums="${GITHUB_ACTION_PATH}/terraform.sha256"
  local sha name
  [[ -f "${sums}" ]] || die "The pinned Terraform checksums are missing: ${sums}"
  while read -r sha name; do
    if [[ "${name}" == "${archive}" ]]; then
      echo "${sha}"
      return 0
    fi
  done < "${sums}"
  die "Terraform archive '${archive}' is not pinned. Pinned archives: $(cut -d' ' -f3 "${sums}" | tr '\n' ' ')"
}

cmd_terraform() {
  local version="${1:-}"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Terraform version '${version}'. Use X.Y.Z."

  local platform archive sha dir
  platform="$(runner_platform)"
  archive="terraform_${version}_${platform}.zip"
  sha="$(pinned_terraform_sha256 "${archive}")"
  dir="$(tools_dir)"
  mkdir -p "${dir}/bin"

  download_checked "${TERRAFORM_RELEASES_URL}/${version}/${archive}" "${sha}" "${dir}/${archive}"
  unzip -o -q "${dir}/${archive}" terraform -d "${dir}/bin"
  rm -f "${dir}/${archive}"
  chmod 0755 "${dir}/bin/terraform"

  local reported
  reported="$("${dir}/bin/terraform" version | head -n 1)"
  [[ "${reported}" == "Terraform v${version}" ]] \
    || die "The installed Terraform reports '${reported}', not 'Terraform v${version}'."
  write_output terraform-version "${version}"
  write_output terraform-path "${dir}/bin/terraform"
}

# Prints the commit pinned for a source package in cli-sources.txt.
pinned_source_commit() {
  local package="$1"
  local sources="${GITHUB_ACTION_PATH}/cli-sources.txt"
  local name commit
  [[ -f "${sources}" ]] || die "This release of the actions pins no Iltero CLI: ${sources} is missing."
  while read -r name commit; do
    if [[ "${name}" == "${package}" ]]; then
      [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "The pinned commit of ${package} is not a full commit: '${commit}'."
      echo "${commit}"
      return 0
    fi
  done < "${sources}"
  die "cli-sources.txt pins no commit for ${package}."
}

# Runs pip quietly. On failure it prints pip's log and stops.
pip_install() {
  local venv="$1"
  shift
  local log="${venv}.pip.log"
  if ! "${venv}/bin/python" -m pip install --no-input --disable-pip-version-check "$@" > "${log}" 2>&1; then
    cat "${log}" >&2
    die "Installing the Iltero CLI failed."
  fi
}

# Downloads the evaluator release that the installed iltero-schemas pins, and
# checks it against the pinned digest.
install_evaluator() {
  local venv="$1"
  local dir="$2"
  local key pin version asset sha
  case "$(runner_platform)" in
    linux_amd64) key="linux-x86_64" ;;
    linux_arm64) key="linux-aarch64" ;;
    *) die "No evaluator for this runner." ;;
  esac
  pin="$("${venv}/bin/python" -c '
import sys
from iltero_schemas.opa.pin import PIN
binary = PIN.binaries[sys.argv[1]]
print(PIN.release_tag, binary.asset, binary.sha256)
' "${key}")" || die "Cannot read the evaluator pin from iltero-schemas."
  read -r version asset sha <<< "${pin}"
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${asset}" =~ ^[a-z0-9_]+$ && "${sha}" =~ ^[0-9a-f]{64}$ ]] \
    || die "The evaluator pin from iltero-schemas is malformed."

  download_checked "${OPA_RELEASES_URL}/${version}/${asset}" "${sha}" "${dir}/bin/opa"
  chmod 0755 "${dir}/bin/opa"
}

cmd_cli() {
  local requirements="${GITHUB_ACTION_PATH}/cli-requirements.txt"
  [[ -f "${requirements}" ]] || die "This release of the actions pins no Iltero CLI: ${requirements} is missing."

  local schemas_commit cli_commit dir venv
  schemas_commit="$(pinned_source_commit iltero-schemas)"
  cli_commit="$(pinned_source_commit iltero-cli)"
  dir="$(tools_dir)"
  venv="${dir}/venv"
  mkdir -p "${dir}/bin"

  python3 -m venv "${venv}"
  # Every dependency comes from the lock, as a wheel, with a matching hash.
  pip_install "${venv}" --require-hashes --no-deps --only-binary ":all:" -r "${requirements}"
  # The CLI and the contract are built from their pinned commits, with the
  # locked build backend.
  pip_install "${venv}" --no-deps --no-build-isolation \
    "git+${GITHUB_URL}/ilterohq/iltero-schemas.git@${schemas_commit}" \
    "git+${GITHUB_URL}/ilterohq/iltero-cli.git@${cli_commit}"

  local installed_commit
  installed_commit="$("${venv}/bin/python" -c '
import json
from importlib.metadata import distribution
print(json.loads(distribution("iltero").read_text("direct_url.json"))["vcs_info"]["commit_id"])
')" || die "Cannot read which commit of the CLI was installed."
  [[ "${installed_commit}" == "${cli_commit}" ]] \
    || die "The installed CLI is commit '${installed_commit}', not the pinned '${cli_commit}'."

  install_evaluator "${venv}" "${dir}"
  ILTERO_OPA_PATH="${dir}/bin/opa" "${venv}/bin/iltero" doctor \
    || die "The Iltero CLI is installed but not ready to run checks."

  write_output cli-commit "${cli_commit}"
  write_output cli-path "${venv}/bin/iltero"
  write_output opa-path "${dir}/bin/opa"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    terraform) cmd_terraform "$@" ;;
    cli) cmd_cli ;;
    *) die "Unknown command '${command}'. Use: check | terraform VERSION | cli" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
