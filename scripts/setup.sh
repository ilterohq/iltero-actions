#!/bin/bash
#
# Installs the tools the other actions use: the Iltero CLI and its evaluator,
# the policy engine that runs the assertions. The deploy and preview actions
# install the Terraform they run themselves.
#
# Usage:
#   setup.sh check    Refuse untrusted events and unsupported runners.
#   setup.sh cli      Install the Iltero CLI and its evaluator at the pinned versions.
#
# GITHUB_ACTION_PATH is the `setup/` folder. It holds the pins:
#   cli-sources.txt           The commits of iltero-schemas and iltero-cli to install.
#   cli-requirements.txt      Every other package the CLI needs, with hashes.
#                             Written by scripts/lock-cli.py.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/install.sh"

readonly OPA_RELEASES_URL="https://github.com/open-policy-agent/opa/releases/download"
readonly GITHUB_URL="https://github.com"
cmd_check() {
  refuse_untrusted_event
  runner_platform > /dev/null
}

# Prints the commit pinned for a source package in cli-sources.txt.
pinned_source_commit() {
  local package="$1"
  local sources="${GITHUB_ACTION_PATH}/cli-sources.txt"
  local name commit
  [[ -f "${sources}" ]] || die "This release of the actions pins no Iltero CLI: ${sources} is missing."
  while read -r name commit; do
    if [[ "${name}" == "${package}" ]]; then
      [[ "${commit}" =~ ${COMMIT_PATTERN} ]] || die "The pinned commit of ${package} is not a full commit: '${commit}'."
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
  if ! "${venv}/bin/python" -I -m pip install --no-input --disable-pip-version-check "$@" > "${log}" 2>&1; then
    cat "${log}" >&2
    die "Installing the Iltero CLI failed."
  fi
}

# Downloads the evaluator release that the installed iltero-schemas pins, as
# the CLI reports it, and checks it against the pinned digest.
install_evaluator() {
  local venv="$1"
  local dir="$2"
  local platform pin version asset sha extra
  case "$(runner_platform)" in
    linux_amd64) platform="linux-x86_64" ;;
    linux_arm64) platform="linux-aarch64" ;;
    *) die "No evaluator for this runner." ;;
  esac
  pin="$("${venv}/bin/iltero" evaluator pin --platform "${platform}")" \
    || die "The Iltero CLI could not report the evaluator pin for ${platform}."
  read -r version asset sha extra <<< "${pin}"
  [[ "${pin}" != *$'\n'* && -z "${extra}" && "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "${asset}" =~ ^[${LOWER}0-9_]+$ && "${sha}" =~ ${SHA256_PATTERN} ]] \
    || die "The evaluator pin the Iltero CLI reports is malformed."

  download_checked "${OPA_RELEASES_URL}/${version}/${asset}" "${sha}" "${dir}/bin/opa"
  chmod 0755 "${dir}/bin/opa"
}

# Stops unless the package DISTRIBUTION in VENV was installed from COMMIT.
# LABEL names it in the message.
check_installed_commit() {
  local venv="$1"
  local distribution="$2"
  local commit="$3"
  local label="$4"
  local installed
  installed="$("${venv}/bin/python" -I -c '
import json, sys
from importlib.metadata import distribution
print(json.loads(distribution(sys.argv[1]).read_text("direct_url.json"))["vcs_info"]["commit_id"])
' "${distribution}")" || die "Cannot read the commit of the installed ${label}."
  [[ "${installed}" == "${commit}" ]] \
    || die "The installed ${label} is commit '${installed}', not the pinned '${commit}'."
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

  python3 -I -m venv "${venv}"
  # Every dependency comes from the lock, as a wheel, with a matching hash.
  pip_install "${venv}" --require-hashes --no-deps --only-binary ":all:" -r "${requirements}"
  # The CLI and iltero-schemas are built from their pinned commits, with the
  # locked build backend.
  pip_install "${venv}" --no-deps --no-build-isolation \
    "git+${GITHUB_URL}/ilterohq/iltero-schemas.git@${schemas_commit}" \
    "git+${GITHUB_URL}/ilterohq/iltero-cli.git@${cli_commit}"

  check_installed_commit "${venv}" iltero "${cli_commit}" "CLI"
  check_installed_commit "${venv}" iltero-schemas "${schemas_commit}" "iltero-schemas"

  install_evaluator "${venv}" "${dir}"
  ILTERO_OPA_PATH="${dir}/bin/opa" "${venv}/bin/iltero" doctor \
    || die "The Iltero CLI is installed but not ready to run checks."

  write_output cli-commit "${cli_commit}"
  write_output cli-path "${venv}/bin/iltero"
  write_output evaluator-path "${dir}/bin/opa"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) cmd_check ;;
    cli) cmd_cli ;;
    *) die "Unknown command '${command}'. Use: check | cli" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
