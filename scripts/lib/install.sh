#!/bin/bash
#
# Downloads a pinned tool and checks it. Source this file after common.sh.

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

# Prints the platform name of this runner, as Terraform's releases name it,
# or stops on an unsupported runner. Only Linux runners on x64 or ARM64 are
# supported.
runner_platform() {
  [[ "${RUNNER_OS:-}" == "Linux" ]] || die "Unsupported runner OS '${RUNNER_OS:-}'. Use a Linux runner."
  case "${RUNNER_ARCH:-}" in
    X64) echo "linux_amd64" ;;
    ARM64) echo "linux_arm64" ;;
    *) die "Unsupported runner architecture '${RUNNER_ARCH:-}'. Use an X64 or ARM64 runner." ;;
  esac
}
