#!/usr/bin/env bats
#
# Tests for scripts/lock-cli.py, which pins the Iltero CLI that `setup`
# installs. Each test runs a copy of the script, so it writes a setup/ folder
# of its own, against a git checkout that holds a small lock file.

load test_helper

setup() {
  SCHEMAS_COMMIT="$(printf 'b%.0s' {1..40})"
  TREE="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${TREE}/scripts" "${TREE}/setup"
  cp "${REPO_ROOT}/scripts/lock-cli.py" "${TREE}/scripts/"
  LOCK_CLI="${TREE}/scripts/lock-cli.py"

  CHECKOUT="${BATS_TEST_TMPDIR}/cli"
  mkdir -p "${CHECKOUT}"
  git -C "${CHECKOUT}" init -q
  git -C "${CHECKOUT}" config user.email "test@example.com"
  git -C "${CHECKOUT}" config user.name "test"
  write_lock "sha256:committed"
  git -C "${CHECKOUT}" add pdm.lock
  git -C "${CHECKOUT}" commit -q -m lock
  CLI_COMMIT="$(git -C "${CHECKOUT}" rev-parse HEAD)"
}

# Writes the checkout's lock file. HASH is the hash of the CLI's one default
# package.
write_lock() {
  local hash="$1"
  cat > "${CHECKOUT}/pdm.lock" << TOML
[[package]]
name = "typer"
version = "1.0.0"
groups = ["default"]
files = [{hash = "${hash}"}]

[[package]]
name = "boto3"
version = "2.0.0"
groups = ["aws"]
files = [{hash = "sha256:boto"}]

[[package]]
name = "pytest"
version = "8.0.0"
groups = ["dev"]
files = [{hash = "sha256:pytest"}]

[[package]]
name = "iltero-schemas"
version = "0.1.0"
groups = ["default"]
files = [{hash = "sha256:schemas"}]

[[package]]
name = "hatchling"
version = "1.0.0"
groups = ["build"]
dependencies = ["pathspec>=0.10"]
files = [{hash = "sha256:hatchling"}]

[[package]]
name = "pathspec"
version = "0.12.0"
groups = ["build"]
files = [{hash = "sha256:pathspec"}]
TOML
}

lock() {
  run python3 -I "${LOCK_CLI}" "${CHECKOUT}" "${SCHEMAS_COMMIT}"
}

@test "the sources file names both pinned commits" {
  lock
  [ "${status}" -eq 0 ]
  [ "$(cat "${TREE}/setup/cli-sources.txt")" = "$(printf 'iltero-schemas %s\niltero-cli %s' "${SCHEMAS_COMMIT}" "${CLI_COMMIT}")" ]
  grep -qx "# Iltero CLI commit: ${CLI_COMMIT}" "${TREE}/setup/cli-requirements.txt"
}

@test "the requirements hold the default and cloud packages and the build backend, each with its hash" {
  lock
  local requirements="${TREE}/setup/cli-requirements.txt"
  grep -qx 'typer==1.0.0 \\' "${requirements}"
  grep -qx 'boto3==2.0.0 \\' "${requirements}"
  grep -qx 'hatchling==1.0.0 \\' "${requirements}"
  grep -qx 'pathspec==0.12.0 \\' "${requirements}"
  grep -qx '    --hash=sha256:boto' "${requirements}"
}

@test "development packages and the source-installed contract are left out" {
  lock
  ! grep -q "^pytest==" "${TREE}/setup/cli-requirements.txt" || false
  ! grep -q "^iltero-schemas==" "${TREE}/setup/cli-requirements.txt" || false
}

@test "the lock file is read as committed, never from the working tree" {
  write_lock "sha256:uncommitted"
  lock
  [ "${status}" -eq 0 ]
  grep -qx '    --hash=sha256:committed' "${TREE}/setup/cli-requirements.txt"
  ! grep -q "uncommitted" "${TREE}/setup/cli-requirements.txt" || false
}

@test "a schemas commit that is not a full commit is refused" {
  run python3 -I "${LOCK_CLI}" "${CHECKOUT}" abc123
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"SCHEMAS_COMMIT must be a full 40-character commit"* ]]
}

@test "a package with no hashes is refused" {
  sed -i.bak 's/^files = \[{hash = "sha256:committed"}\]$/files = []/' "${CHECKOUT}/pdm.lock"
  git -C "${CHECKOUT}" commit -q -am "no hashes"
  lock
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"typer has no hashes in the lock file"* ]]
}

@test "a commit with no lock file is refused" {
  git -C "${CHECKOUT}" rm -q pdm.lock
  git -C "${CHECKOUT}" commit -q -m "no lock"
  lock
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"the commit at HEAD has no pdm.lock"* ]]
}
