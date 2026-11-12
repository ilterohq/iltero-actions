#!/usr/bin/env bats
#
# Rules every action and workflow in the repository must follow.

load test_helper

# Prints every action, workflow and example workflow file, one per line.
yaml_files() {
  cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -- '*/action.yml' '.github/workflows/*.yml' 'examples/*/*.yml'
}

action_files() {
  cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -- '*/action.yml'
}

@test "every uses: names a full commit SHA with a version comment" {
  local file bad=""
  while IFS= read -r file; do
    bad+="$(grep -nE '^\s*-?\s*uses:' "${REPO_ROOT}/${file}" \
      | grep -vE 'uses: [^@[:space:]]+@[0-9a-f]{40} # v[0-9]' \
      | grep -vE 'uses: \./' | sed "s|^|${file}:|")"
  done < <(yaml_files)
  [ -z "${bad}" ] || { echo "${bad}"; false; }
}

@test "no action calls another action of this repository through uses:" {
  local file bad=""
  while IFS= read -r file; do
    bad+="$(grep -nE 'uses: (\./|ilterohq/iltero-actions)' "${REPO_ROOT}/${file}" | sed "s|^|${file}:|")"
  done < <(action_files)
  [ -z "${bad}" ] || { echo "${bad}"; false; }
}

@test "no run: block in an action contains an expression" {
  local file
  for file in $(action_files); do
    run awk '
      /^[[:space:]]*(-[[:space:]]+)?run:/ { in_run = 1; indent = match($0, /[^ ]/); if (index($0, "${{")) { print FILENAME ":" NR; bad = 1 } next }
      in_run && NF && match($0, /[^ ]/) <= indent { in_run = 0 }
      in_run && index($0, "${{") { print FILENAME ":" NR; bad = 1 }
      END { exit bad }' "${REPO_ROOT}/${file}"
    [ "${status}" -eq 0 ] || { echo "${output}"; false; }
  done
}

@test "no action or action script uses jq or yq" {
  run bash -c "cd '${REPO_ROOT}' && grep -rnwE 'jq|yq' --include='*.sh' --include='*.py' --include=action.yml scripts */action.yml"
  [ "${status}" -eq 1 ] || { echo "${output}"; false; }
}

@test "every script runs Python isolated from the folder it runs in" {
  run bash -c "cd '${REPO_ROOT}' && grep -rnE --include='*.sh' --include=action.yml 'python[0-9.]*\"? ' scripts */action.yml | grep -vE 'python[0-9.]*\"? -I '"
  [ "${status}" -eq 1 ] || { echo "${output}"; false; }
}

@test "deploy and preview default to the same Terraform version, with a pinned checksum for each runner architecture" {
  local action version versions=()
  for action in deploy preview; do
    version="$(awk '/^  terraform-version:$/ { inside = 1 } inside && /^    default: / { gsub(/"/, "", $2); print $2; exit }' "${REPO_ROOT}/${action}/action.yml")"
    [ -n "${version}" ]
    versions+=("${version}")
  done
  [ "${versions[0]}" = "${versions[1]}" ]
  grep -qE "^[0-9a-f]{64}  terraform_${versions[0]}_linux_amd64\.zip$" "${REPO_ROOT}/scripts/iac/terraform.sha256"
  grep -qE "^[0-9a-f]{64}  terraform_${versions[0]}_linux_arm64\.zip$" "${REPO_ROOT}/scripts/iac/terraform.sha256"
}

@test "the locked requirements belong to the pinned CLI commit" {
  local commit
  commit="$(awk '$1 == "iltero-cli" { print $2 }' "${REPO_ROOT}/setup/cli-sources.txt")"
  grep -qx "# Iltero CLI commit: ${commit}" "${REPO_ROOT}/setup/cli-requirements.txt"
}

@test "no records or report upload sets its own retention, so the repository's setting applies" {
  local file
  for file in deploy verify record-iac record-image; do
    ! grep -n 'retention-days' "${REPO_ROOT}/${file}/action.yml" || false
  done
}

@test "an empty records upload of record-iac and record-image gives a warning" {
  local file
  for file in record-iac record-image; do
    grep -A6 'name: Upload the records' "${REPO_ROOT}/${file}/action.yml" | grep -qx '        if-no-files-found: warn'
  done
}

@test "no script reads the CLI's records or contract package itself" {
  run bash -c "cd '${REPO_ROOT}' && grep -rnE 'iltero_schemas|expected_stages|json\.load\(record' --include='*.sh' --include=action.yml scripts */action.yml"
  [ "${status}" -eq 1 ] || { echo "${output}"; false; }
}

@test "no tracked file holds a NUL byte" {
  run bash -c "cd '${REPO_ROOT}' && git ls-files -z | python3 -I scripts/find-nul-bytes.py"
  [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "the NUL-byte check finds a file that holds one, and fails on a missing file" {
  printf 'echo "\0"\n' > "${BATS_TEST_TMPDIR}/with-nul.sh"
  echo 'clean' > "${BATS_TEST_TMPDIR}/clean.sh"
  run bash -c "printf '%s\0' '${BATS_TEST_TMPDIR}/clean.sh' '${BATS_TEST_TMPDIR}/with-nul.sh' | python3 -I '${REPO_ROOT}/scripts/find-nul-bytes.py'"
  [ "${status}" -eq 1 ]
  [ "${output}" = "${BATS_TEST_TMPDIR}/with-nul.sh" ]
  run bash -c "printf '%s\0' '${BATS_TEST_TMPDIR}/missing.sh' | python3 -I '${REPO_ROOT}/scripts/find-nul-bytes.py'"
  [ "${status}" -ne 0 ]
}

@test "no file names an Iltero secret" {
  run bash -c "cd '${REPO_ROOT}' && git grep -nE 'ILTERO_(TOKEN|REGISTRY_TOKEN|RUN_TOKEN|OIDC_TOKEN)' -- ':!tests/structure.bats'"
  [ "${status}" -eq 1 ] || { echo "${output}"; false; }
}

@test "every action checks the event before anything else" {
  local file first
  for file in $(action_files); do
    first="$(grep -m1 -E '^\s*(run|uses):' "${REPO_ROOT}/${file}")"
    [[ "${first}" == *'scripts/'*'.sh" check'* ]] || { echo "${file}: first step is '${first}'"; false; }
  done
}

@test "every pinned Terraform checksum is well formed" {
  run grep -vcE '^[0-9a-f]{64}  terraform_[0-9]+\.[0-9]+\.[0-9]+_linux_(amd64|arm64)\.zip$' "${REPO_ROOT}/scripts/iac/terraform.sha256"
  [ "${output}" = "0" ]
}

@test "the CLI is pinned to full commits" {
  run grep -vcE '^iltero-(schemas|cli) [0-9a-f]{40}$' "${REPO_ROOT}/setup/cli-sources.txt"
  [ "${output}" = "0" ]
}
