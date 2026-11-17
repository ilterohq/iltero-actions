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

@test "no run: block in an action, workflow or example contains an expression" {
  local file
  for file in $(yaml_files); do
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

# The pinned checksums of the Terraform adapter.
TERRAFORM_CHECKSUMS="${REPO_ROOT}/scripts/iac/tools/terraform/checksums.sha256"

@test "deploy and preview default to terraform at the adapter's default version, pinned for each runner architecture" {
  local action version
  for action in deploy preview; do
    awk '/^  tool:$/ { inside = 1 } inside && /^    default: / { print $2; exit }' "${REPO_ROOT}/${action}/action.yml" \
      | grep -qx terraform
    awk '/^  tool-version:$/ { inside = 1 } inside && /^    default: / { print $2; exit }' "${REPO_ROOT}/${action}/action.yml" \
      | grep -qx '""'
  done
  version="$(sed -n 's/^readonly TOOL_DEFAULT_VERSION="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/iac/tools/terraform/tool.sh")"
  [ -n "${version}" ]
  grep -qE "^[0-9a-f]{64}  terraform_${version}_linux_amd64\.zip$" "${TERRAFORM_CHECKSUMS}"
  grep -qE "^[0-9a-f]{64}  terraform_${version}_linux_arm64\.zip$" "${TERRAFORM_CHECKSUMS}"
}

@test "every records and report upload keeps its artifact for the retention-days input, empty by default" {
  local file
  for file in deploy verify record-iac record-image; do
    [ "$(grep -c 'uses: actions/upload-artifact@' "${REPO_ROOT}/${file}/action.yml")" -eq \
      "$(grep -cx '        retention-days: ${{ inputs.retention-days }}' "${REPO_ROOT}/${file}/action.yml")" ]
    grep -A5 '^  retention-days:$' "${REPO_ROOT}/${file}/action.yml" | grep -qx '    default: ""'
    # The check step gets the input, so a bad value stops the job before anything runs.
    grep -A5 'name: Check the event and the job' "${REPO_ROOT}/${file}/action.yml" \
      | grep -qx '        RETENTION_DAYS: ${{ inputs.retention-days }}'
  done
}

@test "record-image fails on failed assertions unless the workflow says otherwise" {
  grep -A10 '^  fail-on-failed-assertions:$' "${REPO_ROOT}/record-image/action.yml" | grep -qx '    default: "true"'
}

@test "an empty records upload of record-iac and record-image gives a warning" {
  local file
  for file in record-iac record-image; do
    grep -A8 'name: Upload the records' "${REPO_ROOT}/${file}/action.yml" | grep -qx '        if-no-files-found: warn'
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

@test "every pinned Terraform checksum is well formed, and there is at least one" {
  [ -s "${TERRAFORM_CHECKSUMS}" ]
  run grep -vcE '^[0-9a-f]{64}  terraform_[0-9]+\.[0-9]+\.[0-9]+_linux_(amd64|arm64)\.zip$' "${TERRAFORM_CHECKSUMS}"
  [ "${output}" = "0" ]
}

@test "the CLI and iltero-schemas are each pinned to one full commit" {
  local sources="${REPO_ROOT}/setup/cli-sources.txt"
  run grep -vcE '^iltero-(schemas|cli) [0-9a-f]{40}$' "${sources}"
  [ "${output}" = "0" ]
  [ "$(grep -c '^iltero-cli ' "${sources}")" -eq 1 ]
  [ "$(grep -c '^iltero-schemas ' "${sources}")" -eq 1 ]
}

@test "every run: step of a composite action names its shell" {
  local file bad=""
  for file in $(action_files); do
    bad+="$(awk '
      /^    - / { if (step && has_run && !has_shell) print FILENAME ":" start; step = 1; start = NR; has_run = 0; has_shell = 0 }
      /^      run:/ || /^    - run:/ { has_run = 1 }
      /^      shell: / || /^    - shell: / { has_shell = 1 }
      END { if (step && has_run && !has_shell) print FILENAME ":" start }' "${REPO_ROOT}/${file}")"
  done
  [ -z "${bad}" ] || { echo "${bad}"; false; }
}

@test "every tool adapter is supported, and every supported tool has an adapter that defines the whole interface" {
  local adapters supported tool
  adapters="$(cd "${REPO_ROOT}/scripts/iac/tools" && ls -d -- */ | tr -d / | sort | paste -sd' ' -)"
  supported="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; printf '%s\\n' \"\${SUPPORTED_TOOLS[@]}\" | sort | paste -sd' ' -")"
  [ "${adapters}" = "${supported}" ]
  for tool in ${supported}; do
    # load_tool stops when the adapter misses any function or constant of the interface.
    run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool '${tool}'"
    [ "${status}" -eq 0 ] || { echo "${tool}: ${output}"; false; }
  done
}

@test "an adapter that misses part of the interface is refused" {
  local copy="${BATS_TEST_TMPDIR}/scripts"
  cp -R "${REPO_ROOT}/scripts" "${copy}"
  sed -i '/^tool_apply() {/,/^}/d' "${copy}/iac/tools/terraform/tool.sh"
  run bash -c "source '${copy}/lib/common.sh'; source '${copy}/iac/lib/tool.sh'; load_tool terraform"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The adapter of the tool 'terraform' does not define tool_apply."* ]]
}

@test "the cloud adapters give deploy credential names and preview mock credentials" {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/cloud-credentials.sh'
    [[ \${#CLOUD_CREDENTIAL_ENV[@]} -gt 0 && \${#PREVIEW_CREDENTIAL_ENV[@]} -gt 0 ]]"
  [ "${status}" -eq 0 ]
}

@test "Terraform's default version is the newest one pinned, and the docs name it" {
  local default newest
  default="$(sed -n 's/^readonly TOOL_DEFAULT_VERSION="\(.*\)"$/\1/p' "${REPO_ROOT}/scripts/iac/tools/terraform/tool.sh")"
  newest="$(sed -E 's/.*terraform_([0-9.]+)_linux.*/\1/' "${TERRAFORM_CHECKSUMS}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ "${default}" = "${newest}" ]
  grep -q "Terraform ${default}" "${REPO_ROOT}/docs/README.md"
}

@test "the end-to-end test stack needs no Iltero account and runs no starter assertion" {
  local config="${REPO_ROOT}/tests/e2e/stack/.iltero/config.yml"
  ! grep -q '^platform:' "${config}" || false
  grep -qx '  include_starter_assertions: false' "${config}"
}

@test "the end-to-end CI job, which runs pull request code, may only read the repository and keeps no credential" {
  local ci="${REPO_ROOT}/.github/workflows/ci.yml" job
  job="$(awk '/^  [a-z-]+:$/ { inside = ($1 == "end-to-end:") } inside' "${ci}")"
  [ -n "${job}" ]
  [ "$(grep -E '^      [a-z-]+: (read|write)' <<< "${job}")" = "      contents: read" ]
  ! grep -q 'id-token' <<< "${job}" || false
  [ "$(grep -c 'persist-credentials: false' <<< "${job}")" -eq "$(grep -c 'actions/checkout@' <<< "${job}")" ]
}

@test "a failure of the end-to-end CI job does not fail the workflow while the CLI's repository is private" {
  local ci="${REPO_ROOT}/.github/workflows/ci.yml" job
  job="$(awk '/^  [a-z-]+:$/ { inside = ($1 == "end-to-end:") } inside' "${ci}")"
  grep -qx '    continue-on-error: true' <<< "${job}"
}
