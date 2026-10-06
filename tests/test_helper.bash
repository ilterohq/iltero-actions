#!/bin/bash
#
# Shared setup for the BATS suites. Each test gets an empty runner layout and a
# folder of stub commands placed first on PATH.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export REPO_ROOT

# Creates the runner environment a composite step sees.
make_runner() {
  export RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner-temp"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github-output"
  export GITHUB_EVENT_NAME="push"
  export RUNNER_OS="Linux"
  export RUNNER_ARCH="X64"
  export STUBS="${BATS_TEST_TMPDIR}/stubs"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log"
  export FIXTURES="${BATS_TEST_TMPDIR}/fixtures"
  mkdir -p "${RUNNER_TEMP}" "${STUBS}" "${FIXTURES}"
  : > "${GITHUB_OUTPUT}"
  : > "${STUB_LOG}"
  export PATH="${STUBS}:${PATH}"
}

# Writes an executable stub command.
stub() {
  local name="$1"
  local body="$2"
  printf '#!/bin/bash\n%s\n' "${body}" > "${STUBS}/${name}"
  chmod +x "${STUBS}/${name}"
}

# A curl stub that serves files from FIXTURES by the URL's last path segment,
# and records each URL it was asked for.
stub_curl() {
  stub curl '
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "curl ${url}" >> "${STUB_LOG}"
fixture="${FIXTURES}/${url##*/}"
[[ -f "${fixture}" ]] || exit 22
cp "${fixture}" "${out}"'
}

# Prints the SHA-256 of a file.
sha256_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# Prints the value of one output written to GITHUB_OUTPUT.
output_value() {
  local name="$1"
  grep "^${name}=" "${GITHUB_OUTPUT}" | cut -d= -f2-
}
