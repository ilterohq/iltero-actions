#!/usr/bin/env bats
#
# Rules every action and workflow in the repository must follow.

load test_helper

# Prints every action and workflow file, one per line.
yaml_files() {
  cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -- '*/action.yml' '.github/workflows/*.yml'
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
  run bash -c "cd '${REPO_ROOT}' && grep -nwE 'jq|yq' */action.yml scripts/*.sh scripts/lib/*.sh"
  [ "${status}" -eq 1 ] || { echo "${output}"; false; }
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
  run grep -vcE '^[0-9a-f]{64}  terraform_[0-9]+\.[0-9]+\.[0-9]+_linux_(amd64|arm64)\.zip$' "${REPO_ROOT}/setup/terraform.sha256"
  [ "${output}" = "0" ]
}

@test "the CLI is pinned to full commits" {
  run grep -vcE '^iltero-(schemas|cli) [0-9a-f]{40}$' "${REPO_ROOT}/setup/cli-sources.txt"
  [ "${output}" = "0" ]
}
