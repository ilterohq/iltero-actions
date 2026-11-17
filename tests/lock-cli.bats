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
}

@test "only the sources file names the pinned commits, never the requirements file" {
  lock
  [ "${status}" -eq 0 ]
  ! grep -q "${CLI_COMMIT}" "${TREE}/setup/cli-requirements.txt" || false
  ! grep -q "${SCHEMAS_COMMIT}" "${TREE}/setup/cli-requirements.txt" || false
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

@test "a lock file entry repeated for a package's extras, with the same version and files, is accepted once" {
  cat >> "${CHECKOUT}/pdm.lock" << 'TOML'

[[package]]
name = "typer"
version = "1.0.0"
extras = ["all"]
groups = ["default"]
files = [{hash = "sha256:committed"}]
TOML
  git -C "${CHECKOUT}" commit -q -am "typer with extras"
  lock
  [ "${status}" -eq 0 ]
  [ "$(grep -c '^typer==' "${TREE}/setup/cli-requirements.txt")" -eq 1 ]
}

@test "a lock file with two different entries for one package is refused, whatever the name's case or separators" {
  local name
  for name in typer Typer TYPER; do
    write_lock "sha256:committed"
    cat >> "${CHECKOUT}/pdm.lock" << TOML

[[package]]
name = "${name}"
version = "2.0.0"
groups = ["default"]
files = [{hash = "sha256:other"}]
TOML
    git -C "${CHECKOUT}" commit -q -am "two ${name} entries"
    lock
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"the lock file has two different entries for ${name}"* ]]
  done
}

@test "the requirements come from the lock file of the commit the sources file pins" {
  lock
  [ "${status}" -eq 0 ]
  grep -qx "iltero-cli ${CLI_COMMIT}" "${TREE}/setup/cli-sources.txt"
  grep -q "sha256:committed" "${TREE}/setup/cli-requirements.txt"
}

@test "a lock entry in no group is left out of the requirements" {
  cat >> "${CHECKOUT}/pdm.lock" << 'TOML'

[[package]]
name = "groupless"
version = "1.0.0"
files = [{hash = "sha256:groupless"}]
TOML
  git -C "${CHECKOUT}" commit -q -am "an entry in no group"
  lock
  [ "${status}" -eq 0 ]
  ! grep -q "groupless" "${TREE}/setup/cli-requirements.txt" || false
}

@test "a CLI checkout that is not a git checkout is refused with a message, not a traceback" {
  mkdir -p "${BATS_TEST_TMPDIR}/not-a-checkout"
  run python3 -I "${LOCK_CLI}" "${BATS_TEST_TMPDIR}/not-a-checkout" "${SCHEMAS_COMMIT}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"is not a git checkout with a commit at HEAD"* ]]
  [[ "${output}" != *"Traceback"* ]]
}

@test "names that differ only by separator are one package" {
  cat >> "${CHECKOUT}/pdm.lock" << 'TOML'

[[package]]
name = "ty-per"
version = "1.0.0"
groups = ["default"]
files = [{hash = "sha256:a"}]

[[package]]
name = "ty_per"
version = "2.0.0"
groups = ["default"]
files = [{hash = "sha256:b"}]
TOML
  git -C "${CHECKOUT}" commit -q -am "one package under two spellings"
  lock
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"the lock file has two different entries for ty_per"* ]]
}

@test "a repeated entry adds its groups, so a package installed only with extras is still locked" {
  cat >> "${CHECKOUT}/pdm.lock" << 'TOML'

[[package]]
name = "extra-only"
version = "1.0.0"
groups = ["dev"]
files = [{hash = "sha256:extra"}]

[[package]]
name = "extra-only"
version = "1.0.0"
extras = ["fast"]
groups = ["default"]
files = [{hash = "sha256:extra"}]
TOML
  git -C "${CHECKOUT}" commit -q -am "a package in default only with extras"
  lock
  [ "${status}" -eq 0 ]
  grep -q "^extra-only==1.0.0" "${TREE}/setup/cli-requirements.txt"
}
