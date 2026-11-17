#!/usr/bin/env bats
#
# Tests for scripts/iac/install-tool.sh, which installs the IaC tool that the
# deploy and preview actions run, here through the Terraform adapter. Each test runs a copy of the
# scripts, so it can pin checksums of its own.

# The stubs these tests write expand their variables when they run, not here.
# shellcheck disable=SC2016

load ../test_helper

readonly TF_VERSION="9.8.7"

setup() {
  make_runner
  stub_curl
  cp -r "${REPO_ROOT}/scripts" "${BATS_TEST_TMPDIR}/scripts"
  INSTALL="${BATS_TEST_TMPDIR}/scripts/iac/install-tool.sh"
  CHECKSUMS="${BATS_TEST_TMPDIR}/scripts/iac/tools/terraform/checksums.sha256"
}

# A Terraform release archive whose binary reports REPORTED_VERSION, pinned
# under the archive name for this runner.
terraform_release() {
  local reported="${1:-${TF_VERSION}}"
  local build="${BATS_TEST_TMPDIR}/tf-build"
  mkdir -p "${build}"
  printf '#!/bin/bash\necho "Terraform v%s"\necho "on linux_amd64"\n' "${reported}" > "${build}/terraform"
  chmod +x "${build}/terraform"
  (cd "${build}" && zip -q "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip" terraform)
  echo "$(sha256_of "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip")  terraform_${TF_VERSION}_linux_amd64.zip" \
    > "${CHECKSUMS}"
}

@test "terraform rejects a malformed version" {
  terraform_release
  run "${INSTALL}" terraform "1.16"
  [ "${status}" -eq 1 ]
  run "${INSTALL}" terraform "1.16.5; rm -rf /"
  [ "${status}" -eq 1 ]
}

@test "terraform refuses a version that is not pinned" {
  terraform_release
  run "${INSTALL}" terraform "1.2.3"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform 1.2.3 is not a version this action can install. It can install: ${TF_VERSION}."* ]]
  ! grep -q curl "${STUB_LOG}" || false
}

@test "terraform installs a pinned version and writes its outputs" {
  terraform_release
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
  grep -q "curl https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" "${STUB_LOG}"
  [ "$(output_value tool-version)" = "${TF_VERSION}" ]
  [ "$(output_value tool-path)" = "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
  [ -x "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
}

@test "terraform refuses a download that does not match its checksum" {
  terraform_release
  echo "tampered" >> "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"does not match its pinned checksum"* ]]
  [ ! -e "${RUNNER_TEMP}/iltero-tools/bin/terraform" ]
  [ -z "$(output_value tool-path)" ]
}

@test "terraform fails when the download fails" {
  terraform_release
  rm "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Download failed"* ]]
}

@test "terraform refuses a binary that reports another version" {
  terraform_release "1.0.0"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not 'Terraform v${TF_VERSION}'"* ]]
}

@test "terraform reads the version from a binary that prints many lines" {
  local build="${BATS_TEST_TMPDIR}/tf-build"
  mkdir -p "${build}"
  printf '#!/bin/bash\necho "Terraform v%s"\nfor i in $(seq 1 20000); do echo "provider line ${i}"; done\n' "${TF_VERSION}" > "${build}/terraform"
  chmod +x "${build}/terraform"
  (cd "${build}" && zip -q "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip" terraform)
  echo "$(sha256_of "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip")  terraform_${TF_VERSION}_linux_amd64.zip" \
    > "${CHECKSUMS}"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
  [ "$(output_value tool-version)" = "${TF_VERSION}" ]
}

@test "terraform uses the arm64 archive on ARM64 runners" {
  terraform_release
  RUNNER_ARCH=ARM64 run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Terraform ${TF_VERSION} is not a version this action can install."* ]]
}

@test "every install downloads the archive again and checks it, even when Terraform is already installed" {
  terraform_release
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
  : > "${STUB_LOG}"
  echo "tampered" >> "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  grep -q "curl https://releases.hashicorp.com/terraform/${TF_VERSION}/" "${STUB_LOG}"
  [[ "${output}" == *"does not match its pinned checksum"* ]]
}

@test "the version check runs Terraform with only PATH and HOME, and no update check" {
  local build="${BATS_TEST_TMPDIR}/tf-build"
  mkdir -p "${build}"
  printf '#!/bin/bash\nenv > "%s"\necho "Terraform v%s"\n' "${BATS_TEST_TMPDIR}/terraform-env" "${TF_VERSION}" > "${build}/terraform"
  chmod +x "${build}/terraform"
  (cd "${build}" && zip -q "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip" terraform)
  echo "$(sha256_of "${FIXTURES}/terraform_${TF_VERSION}_linux_amd64.zip")  terraform_${TF_VERSION}_linux_amd64.zip" > "${CHECKSUMS}"
  AWS_SECRET_ACCESS_KEY=secret ACTIONS_ID_TOKEN_REQUEST_TOKEN=token run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
  grep -qx "CHECKPOINT_DISABLE=1" "${BATS_TEST_TMPDIR}/terraform-env"
  # bash adds PWD, SHLVL and _ itself.
  ! cut -d= -f1 "${BATS_TEST_TMPDIR}/terraform-env" | grep -vxE 'PATH|HOME|CHECKPOINT_DISABLE|PWD|SHLVL|_' || false
}

@test "an error message cannot start another workflow command" {
  run "${INSTALL}" terraform $'1.0.0\n::warning::injected 100%'
  [ "${status}" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${output}" == "::error::Invalid Terraform version '1.0.0%0A::warning::injected 100%25'. Use X.Y.Z." ]]
}

@test "the install refuses an unsupported runner" {
  terraform_release
  RUNNER_OS=macOS run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Use a Linux runner"* ]]
}

@test "the install takes a tool and a version" {
  run "${INSTALL}"
  [ "${status}" -eq 1 ]
  run "${INSTALL}" terraform 1.16.5 extra
  [ "${status}" -eq 1 ]
}

@test "the install refuses a tool it has no adapter for" {
  run "${INSTALL}" pulumi 1.0.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The tool input must be one of: terraform. It is 'pulumi'."* ]]
  ! grep -q curl "${STUB_LOG}" || false
}

@test "an empty version installs the adapter's default version" {
  terraform_release
  sed -i "s/^readonly TOOL_DEFAULT_VERSION=.*/readonly TOOL_DEFAULT_VERSION=\"${TF_VERSION}\"/" \
    "${BATS_TEST_TMPDIR}/scripts/iac/tools/terraform/tool.sh"
  run "${INSTALL}" terraform ""
  [ "${status}" -eq 0 ]
  [ "$(output_value tool-version)" = "${TF_VERSION}" ]
}

@test "deploy and preview install the tool before they run it, with the tool and version they are given" {
  local action
  for action in deploy preview; do
    grep -qx '        TOOL_VERSION: ${{ inputs.tool-version }}' "${REPO_ROOT}/${action}/action.yml"
    awk '/^    - name: Install the IaC tool$/ { inside = 1; next } inside && /^    - / { exit } inside { print }' "${REPO_ROOT}/${action}/action.yml" \
      | grep -qx '      id: tool'
    grep -qF 'value: ${{ steps.tool.outputs.tool-path }}' "${REPO_ROOT}/${action}/action.yml"
    [ "$(awk '/^    - name: / { sub(/^    - name: /, ""); print }' "${REPO_ROOT}/${action}/action.yml" | sed -n 2p)" = "Install the IaC tool" ]
    # Every step that runs the action's script, and the install step, names the tool.
    [ "$(($(grep -c "scripts/iac/${action}.sh\"" "${REPO_ROOT}/${action}/action.yml") + 1))" -eq \
      "$(grep -cx '        TOOL: ${{ inputs.tool }}' "${REPO_ROOT}/${action}/action.yml")" ]
  done
}

@test "terraform reads a checksums file whose last line has no newline" {
  terraform_release
  printf '%s' "$(cat "${CHECKSUMS}")" > "${CHECKSUMS}.new" && mv "${CHECKSUMS}.new" "${CHECKSUMS}"
  run "${INSTALL}" terraform "${TF_VERSION}"
  [ "${status}" -eq 0 ]
}
