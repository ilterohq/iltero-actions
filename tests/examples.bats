#!/usr/bin/env bats
#
# The reference workflows under examples/ are what repository owners copy.
# Every action, input and output they use must exist.

# The tests match the examples' expressions and shell text as written.
# shellcheck disable=SC2016

load test_helper

# Prints one line per Iltero step of a workflow: "<id> <action> <input>...".
# A step without an id prints "-" as its id.
iltero_steps() {
  awk '
    function flush() { if (action != "") print (id == "" ? "-" : id), action, inputs; id = ""; action = ""; inputs = ""; in_with = 0 }
    /^      - / { flush() }
    /^      (- |  )id: / { sub(/.*id: */, ""); id = $0 }
    /^      (- |  )uses: ilterohq\/iltero-actions\// { line = $0; sub(/.*iltero-actions\//, "", line); sub(/@.*/, "", line); action = line }
    /^        with:/ { in_with = 1; next }
    in_with && /^          [a-z-]+:/ { key = $1; sub(/:$/, "", key); inputs = inputs " " key; next }
    in_with && !/^          / { in_with = 0 }
    /^  [a-z-]+:$/ { flush() }
    END { flush() }
  ' "$1"
}

# Prints the names declared in one section (inputs or outputs) of an action.
declared() {
  awk -v section="$2" '
    $0 ~ "^" section ":" { inside = 1; next }
    inside && /^[a-z]/ { inside = 0 }
    inside && /^  [a-z-]+:$/ { name = $1; sub(/:$/, "", name); print name }
  ' "${REPO_ROOT}/$1/action.yml"
}

# Prints the inputs of an action marked required: true.
required_inputs() {
  awk '
    /^inputs:/ { inside = 1; next }
    inside && /^[a-z]/ { inside = 0 }
    inside && /^  [a-z-]+:$/ { name = $1; sub(/:$/, "", name) }
    inside && /^    required: true/ { print name }
  ' "${REPO_ROOT}/$1/action.yml"
}

examples() {
  ls "${REPO_ROOT}"/examples/*/*.yml
}

@test "the reference workflows exist" {
  [ -f "${REPO_ROOT}/examples/iac/governed-deploy.yml" ]
  [ -f "${REPO_ROOT}/examples/iac/preview.yml" ]
  [ -f "${REPO_ROOT}/examples/iac/deploy.yml" ]
  [ -f "${REPO_ROOT}/examples/iac/governed-own-terraform.yml" ]
  [ -f "${REPO_ROOT}/examples/iac/own-terraform.yml" ]
  [ -f "${REPO_ROOT}/examples/image/build.yml" ]
  [ -f "${REPO_ROOT}/examples/image/governed-build.yml" ]
  [ -f "${REPO_ROOT}/examples/image/deployment.yml" ]
  [ -f "${REPO_ROOT}/examples/image/governed-deployment.yml" ]
}

@test "every Iltero action an example uses exists" {
  local file id action inputs
  for file in $(examples); do
    while read -r id action inputs; do
      [ -f "${REPO_ROOT}/${action}/action.yml" ] || { echo "${file}: no action '${action}'"; false; }
    done < <(iltero_steps "${file}")
  done
}

@test "every input an example passes is declared, and every required input is passed" {
  local file id action inputs input
  for file in $(examples); do
    while read -r id action inputs; do
      for input in ${inputs}; do
        declared "${action}" inputs | grep -qx "${input}" || { echo "${file}: ${action} has no input '${input}'"; false; }
      done
      for input in $(required_inputs "${action}"); do
        [[ " ${inputs} " == *" ${input} "* ]] || { echo "${file}: ${action} needs input '${input}'"; false; }
      done
    done < <(iltero_steps "${file}")
  done
}

# Prints the step of a workflow whose id is ID, from its "- id:" line to the
# next step.
run_step() {
  awk -v id="$2" '
    /^      - / { inside = ($0 == "      - id: " id) }
    inside { print }
  ' "$1"
}

@test "every step output an example reads is declared by that step's action, or written by its own run step" {
  local file reference id output action
  for file in $(examples); do
    while read -r reference; do
      id="$(echo "${reference}" | cut -d. -f2)"
      output="$(echo "${reference}" | cut -d. -f4)"
      action="$(iltero_steps "${file}" | awk -v id="${id}" '$1 == id { print $2; exit }')"
      if [ -z "${action}" ]; then
        # A one-line output, or a multi-line one between random delimiters.
        run_step "${file}" "${id}" | grep -qE "echo \"${output}=.*>> \"\\$\\{GITHUB_OUTPUT\}\"$|echo \"${output}<<\\$\\{delimiter\}\"$" \
          || { echo "${file}: no run step '${id}' writes output '${output}'"; false; }
        continue
      fi
      declared "${action}" outputs | grep -qx "${output}" || { echo "${file}: ${action} has no output '${output}'"; false; }
    done < <(grep -oE 'steps\.[a-z-]+\.outputs\.[a-z-]+' "${file}" | sort -u)
  done
}

@test "every example grants no permission at the workflow level" {
  local file
  for file in $(examples); do
    grep -qx 'permissions: {}' "${file}" || { echo "${file}"; false; }
  done
}

@test "every checkout in an example leaves no credentials in the checked-out repository" {
  local file
  for file in $(examples); do
    [ "$(grep -c 'actions/checkout@' "${file}")" -eq "$(grep -A2 'actions/checkout@' "${file}" | grep -cx '          persist-credentials: false')" ] || { echo "${file}"; false; }
  done
}

@test "every Iltero action in an example is pinned to the same commit" {
  local file
  for file in $(examples); do
    run bash -c "grep -oE 'ilterohq/iltero-actions/[a-z-]+@[0-9a-f]{40}' '${file}' | cut -d@ -f2 | sort -u | wc -l"
    [ "${output//[[:space:]]/}" = "1" ]
  done
}

@test "the deploy workflows grant only contents: read and id-token: write" {
  local file
  for file in iac/deploy.yml iac/governed-deploy.yml iac/governed-own-terraform.yml iac/own-terraform.yml image/deployment.yml image/governed-deployment.yml; do
    run grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/${file}"
    [ "${status}" -eq 0 ]
    ! grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/${file}" | grep -vE '^      (contents: read|id-token: write)( #.*)?$' || false
  done
}

@test "the workflows that need no account never name a server, open or close a run, or pass a run" {
  local file
  for file in iac/deploy.yml iac/own-terraform.yml image/build.yml image/deployment.yml; do
    ! grep -qE 'iltero-actions/(open|close)@|run-id:|run-settings-digest:|ILTERO_API_URL|store-records:' "${REPO_ROOT}/examples/${file}" || false
  done
  grep -q 'iltero-actions/verify@' "${REPO_ROOT}/examples/iac/deploy.yml"
}

@test "the governed workflows never open a run or pass a run between jobs" {
  local file
  for file in iac/governed-deploy.yml iac/governed-own-terraform.yml image/governed-build.yml image/governed-deployment.yml; do
    ! grep -qE 'iltero-actions/open@|run-id|run-settings-digest' "${REPO_ROOT}/examples/${file}" || false
  done
  # The other governed examples have no job outputs.
  for file in iac/governed-deploy.yml iac/governed-own-terraform.yml image/governed-deployment.yml; do
    ! grep -qE '^    outputs:' "${REPO_ROOT}/examples/${file}" || false
  done
}

# Prints the environment input of the steps of one job of a workflow.
job_environment() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /^          environment: / { print $2 }
  ' "$1" | sort -u
}

@test "each close job of the governed workflows closes its deploy job's environment" {
  local governed_deploy="${REPO_ROOT}/examples/iac/governed-deploy.yml" own_terraform="${REPO_ROOT}/examples/iac/governed-own-terraform.yml"
  [ "$(job_environment "${governed_deploy}" close-staging)" = "$(job_environment "${governed_deploy}" deploy-staging)" ]
  [ "$(job_environment "${governed_deploy}" close-production)" = "$(job_environment "${governed_deploy}" deploy-production)" ]
  [ "$(job_environment "${own_terraform}" close)" = "$(job_environment "${own_terraform}" deploy)" ]
  [ "$(job_environment "${governed_deploy}" close-staging)" = staging ]
  [ "$(job_environment "${own_terraform}" close)" = production ]
  local governed_image="${REPO_ROOT}/examples/image/governed-deployment.yml"
  [ "$(job_environment "${governed_image}" close)" = "$(job_environment "${governed_image}" deploy)" ]
  [ "$(job_environment "${governed_image}" close)" = production ]
}

# Prints the permission lines of one job of a workflow.
job_permissions() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /^      [a-z-]+: (read|write)( #.*)?$/ { sub(/ #.*/, ""); sub(/^ +/, ""); print }
  ' "$1"
}

@test "the preview workflow runs only on pull requests and holds no identity token" {
  grep -qE '^  pull_request:$' "${REPO_ROOT}/examples/iac/preview.yml"
  ! grep -qE 'pull_request_target|workflow_run|id-token' "${REPO_ROOT}/examples/iac/preview.yml" || false
}

@test "the preview job may only read the repository" {
  [ "$(job_permissions "${REPO_ROOT}/examples/iac/preview.yml" preview)" = "contents: read" ]
}

@test "the comment job may only write pull requests, and runs no code from the pull request" {
  [ "$(job_permissions "${REPO_ROOT}/examples/iac/preview.yml" comment)" = "pull-requests: write" ]
  [ "$(awk '/^  comment:$/ { inside = 1; next } /^  [a-z-]+:$/ { inside = 0 } inside && /uses:/ { sub(/.*uses: /, ""); sub(/@.*/, ""); print }' "${REPO_ROOT}/examples/iac/preview.yml")" = "ilterohq/iltero-actions/comment" ]
}

@test "the governed workflows close each run only after its deploy job succeeded" {
  local jobs
  # Prints "<close job> <needs> <job-level if, or ->" for each close job.
  jobs="$(awk '
    function flush() { if (job ~ /^close-/) print job, needs, (cond == "" ? "-" : cond); job = ""; needs = ""; cond = "" }
    /^  [a-z-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
    /^    needs: / { needs = $2 }
    /^    if: / { cond = $0 }
    END { flush() }
  ' "${REPO_ROOT}/examples/iac/governed-deploy.yml")"
  [ "${jobs}" = "$(printf '%s\n' 'close-staging deploy-staging -' 'close-production deploy-production -')" ]
  jobs="$(awk '
    function flush() { if (job == "close") print job, needs, (cond == "" ? "-" : cond); job = ""; needs = ""; cond = "" }
    /^  [a-z-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
    /^    needs: / { needs = $2 }
    /^    if: / { cond = $0 }
    END { flush() }
  ' "${REPO_ROOT}/examples/iac/governed-own-terraform.yml")"
  [ "${jobs}" = "close deploy -" ]
  jobs="$(awk '
    function flush() { if (job == "close") print job, needs, (cond == "" ? "-" : cond); job = ""; needs = ""; cond = "" }
    /^  [a-z-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
    /^    needs: / { needs = $2 }
    /^    if: / { cond = $0 }
    END { flush() }
  ' "${REPO_ROOT}/examples/image/governed-deployment.yml")"
  [ "${jobs}" = "close deploy -" ]
}

# The two own-Terraform examples: with no account, and in a governed run.
own_terraform_examples() {
  echo "${REPO_ROOT}/examples/iac/own-terraform.yml" "${REPO_ROOT}/examples/iac/governed-own-terraform.yml"
}

# Prints the stage of each record-iac step of the example FILE, in order.
record_iac_events() {
  awk '/uses: ilterohq\/iltero-actions\/record-iac@/ { inside = 1; next } inside && /^          stage: / { print $2; inside = 0 }' "$1"
}

@test "the governed own-Terraform example records plan, pre_deploy, post_deploy and post_verify, in that order, as production needs" {
  [ "$(record_iac_events "${REPO_ROOT}/examples/iac/governed-own-terraform.yml" | tr '\n' ' ')" = "plan pre_deploy post_deploy post_verify " ]
}

@test "the own-Terraform example with no account records plan, pre_deploy, post_deploy and post_verify, in that order" {
  [ "$(record_iac_events "${REPO_ROOT}/examples/iac/own-terraform.yml" | tr '\n' ' ')" = "plan pre_deploy post_deploy post_verify " ]
}

# Prints the header comment of the example FILE as one line, with the comment marks removed.
header_text() {
  sed -n '/^[^#]/q; s/^# \{0,1\}//p' "$1" | tr '\n' ' '
}

@test "the examples that deploy Terraform with no account tell the owner to list pre_deploy as out of scope" {
  local file
  for file in iac/deploy.yml iac/own-terraform.yml; do
    header_text "${REPO_ROOT}/examples/${file}" | grep -qF 'list pre_deploy under stages.out_of_scope in .iltero/config.yml'
  done
}

@test "each own-Terraform example reads the deployed resources twice with refresh-only plans, a minute apart" {
  local example
  for example in $(own_terraform_examples); do
    [ "$(grep -c 'terraform plan -input=false -refresh-only ' "${example}")" -eq 2 ]
    grep -A3 'network-first.json"$' "${example}" | grep -qx '          sleep 60'
  done
}

@test "no example uploads or keeps the readings of the deployed resources" {
  local file
  for file in $(examples); do
    ! grep -nE 'readings-directory|network-(first|second)\.json' "${file}" | grep -vE 'terraform show -json|^[0-9]+:            \$\{\{ runner\.temp \}\}/network-(first|second)\.json$' || false
    # The image build examples deploy nothing, and upload only their build and scan files.
    [[ "${file#"${REPO_ROOT}"/examples/}" == image/*build.yml ]] || ! grep -nE 's3 (cp|sync)|s3api|upload-artifact' "${file}" || false
  done
}

@test "no own-Terraform example applies a refresh-only plan" {
  local example
  for example in $(own_terraform_examples); do
    ! grep -E 'terraform apply[^#]*-refresh-only' "${example}" || false
  done
}

@test "no example passes Terraform settings to setup, which installs no Terraform" {
  local file
  for file in $(examples); do
    ! grep -A3 'iltero-actions/setup@' "${file}" | grep -qE '^          (install-terraform|terraform-version):' || false
  done
}

# The two image deployment examples: with no account, and in a governed run.
deployment_examples() {
  echo "${REPO_ROOT}/examples/image/deployment.yml" "${REPO_ROOT}/examples/image/governed-deployment.yml"
}

@test "every deployment stage of the image examples names the environment" {
  local example
  for example in $(deployment_examples); do
    [ "$(grep -cE '^          stage: (pre_deploy|post_deploy|post_verify)$' "${example}")" -eq 3 ]
    [ "$(grep -A3 -E '^          stage: (pre_deploy|post_deploy|post_verify)$' "${example}" | grep -c '^          environment: production$')" -eq 3 ]
  done
}

@test "the deployment examples report the image after a failed deployment too" {
  local example
  for example in $(deployment_examples); do
    grep -qF "if: \${{ !cancelled() && steps.deploy.outcome != 'skipped' }}" "${example}"
    grep -qF "if: \${{ !cancelled() && steps.deployed.outcome == 'success' }}" "${example}"
  done
}

@test "each own-Terraform example installs a Terraform version that the actions pin" {
  local example version
  for example in $(own_terraform_examples); do
    version="$(grep -A2 'hashicorp/setup-terraform@' "${example}" | awk '$1 == "terraform_version:" { print $2 }')"
    [ -n "${version}" ]
    grep -qE "^[0-9a-f]{64}  terraform_${version}_linux_amd64\.zip$" "${REPO_ROOT}/scripts/iac/terraform.sha256"
  done
}

@test "the governed own-Terraform example keeps every stage's record in the run's artifact store, after the cloud credentials are set" {
  local example="${REPO_ROOT}/examples/iac/governed-own-terraform.yml"
  [ "$(grep -c '^          store-records: true$' "${example}")" -eq "$(grep -c 'iltero-actions/record-iac@' "${example}")" ]
  [ "$(grep -n -m1 'configure-aws-credentials@' "${example}" | cut -d: -f1)" -lt "$(grep -n -m1 'store-records: true' "${example}" | cut -d: -f1)" ]
}

@test "each own-Terraform example records the apply also when the state could not be read" {
  local example
  for example in $(own_terraform_examples); do
    grep -qF "state: \${{ steps.state.outcome == 'success' && format('{0}/network-state.json', runner.temp) || '' }}" "${example}"
    grep -qxF "          state-unreadable: \${{ steps.state.outcome == 'failure' }}" "${example}"
    grep -qx "      - id: state" "${example}"
  done
}

@test "each own-Terraform example records post_deploy also after a failed apply" {
  local example condition
  for example in $(own_terraform_examples); do
    # The condition of the record-iac step whose stage is post_deploy.
    condition="$(awk '
      /^      - / { cond = "" }
      /^      - if: / { cond = $0; sub(/^      - if: /, "", cond) }
      /uses: ilterohq\/iltero-actions\/record-iac@/ { inside = 1; next }
      inside && /^          stage: / { if ($2 == "post_deploy") print cond; inside = 0 }
    ' "${example}")"
    [ "${condition}" = "\${{ !cancelled() && steps.apply.outcome != 'skipped' }}" ]
  done
}

@test "each own-Terraform example keeps Terraform's files out of the checked-out repository" {
  local example
  for example in $(own_terraform_examples); do
    ! grep -E -- '-out=|> ' "${example}" | grep -v RUNNER_TEMP || false
    ! grep -E '^          (plan|saved-plan|apply-log|state): ' "${example}" | grep -v 'runner.temp' || false
    grep -q '^          refresh-plans: |$' "${example}"
    ! grep -A2 '^          refresh-plans: |$' "${example}" | tail -n +2 | grep -v 'runner.temp' || false
  done
}

# --- image/build and image/governed-build -----------------------------------

# Prints both image build examples: the one with no account and the governed one.
build_examples() {
  echo "${REPO_ROOT}/examples/image/build.yml" "${REPO_ROOT}/examples/image/governed-build.yml"
}

# Prints the output names of one job of a workflow, separated by spaces.
job_outputs() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { in_job = ($1 == job ":"); in_outputs = 0; next }
    in_job && /^    outputs:$/ { in_outputs = 1; next }
    in_outputs && !/^      / { in_outputs = 0 }
    in_outputs { print $1 }
  ' "$1" | tr '\n' ' '
}

@test "each image build example's build job outputs carry only the image's reference" {
  local example
  for example in $(build_examples); do
    [ "$(job_outputs "${example}" build)" = "image: pushed: " ]
  done
}

@test "only the image build example with no account has a scan job output, which says whether the report was kept" {
  [ "$(job_outputs "${REPO_ROOT}/examples/image/build.yml" scan)" = "report-kept: " ]
  [ -z "$(job_outputs "${REPO_ROOT}/examples/image/governed-build.yml" scan)" ]
  [ -z "$(job_outputs "${REPO_ROOT}/examples/image/build.yml" record)" ]
}

@test "each image build example's build job may only read the source and push the image" {
  local example
  for example in $(build_examples); do
    [ "$(job_permissions "${example}" build)" = "$(printf '%s\n' 'contents: read' 'packages: write')" ]
  done
}

@test "each image build example's scanner may only pull the image, and holds no identity token" {
  local example
  for example in $(build_examples); do
    [ "$(job_permissions "${example}" scan)" = "packages: read" ]
  done
}

@test "the governed image build example's record job may only read the repository and get its identity token" {
  [ "$(job_permissions "${REPO_ROOT}/examples/image/governed-build.yml" record)" = "$(printf '%s\n' 'contents: read' 'id-token: write')" ]
}

@test "the governed image build example keeps the image's record in the build run's artifact store, after the cloud credentials are set" {
  local example="${REPO_ROOT}/examples/image/governed-build.yml"
  [ "$(grep -c '^          store-records: true$' "${example}")" -eq 1 ]
  [ "$(job_actions "${example}" record | grep -v '^actions/' | tr '\n' ' ')" = "ilterohq/iltero-actions/setup aws-actions/configure-aws-credentials ilterohq/iltero-actions/record-image ilterohq/iltero-actions/close " ]
}

@test "in the image build example with no account, the record job may only read the repository, and gets no identity token" {
  [ "$(job_permissions "${REPO_ROOT}/examples/image/build.yml" record)" = "contents: read" ]
}

# Prints the actions one job of a workflow uses, one per line, without their commits.
job_actions() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /uses: / { sub(/.*uses: /, ""); sub(/@.*/, ""); print }
  ' "$1"
}

# Prints the lines of one job of a workflow.
job_lines() {
  awk -v job="$2" '/^  [a-z-]+:$/ { inside = ($1 == job ":"); next } inside' "$1"
}

# Prints the script of the step with the given name, without its indentation.
step_script() {
  awk -v name="$2" '
    /^      - |^  [a-z-]+:$/ { if (body) exit; found = 0 }
    $0 == "      - name: " name || $0 == "        name: " name { found = 1 }
    found && /^        run: \|$/ { body = 1; next }
    body && /^          / { sub(/^          /, ""); print; next }
    body && /^$/ { print ""; next }
    body { exit }
  ' "$1"
}

# Puts a stand-in trivy first on PATH. It logs its arguments to TRIVY_LOG, one
# call per line, and fails a call that names the platform in TRIVY_FAILS_ON.
fake_trivy() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/trivy" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${TRIVY_LOG}"
[[ " $* " != *" ${TRIVY_FAILS_ON:-none} "* ]]
SH
  chmod +x "${BATS_TEST_TMPDIR}/bin/trivy"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" TRIVY_LOG="${BATS_TEST_TMPDIR}/trivy.log"
  : > "${TRIVY_LOG}"
}

@test "each image build example runs the scanner only in the scan job, and Iltero only in the record job" {
  local example
  for example in $(build_examples); do
    job_actions "${example}" scan | grep -q '^aquasecurity/setup-trivy$'
    job_lines "${example}" scan | grep -q 'trivy image '
    ! job_actions "${example}" build | grep -qE 'trivy|iltero' || false
    ! job_actions "${example}" scan | grep -q 'iltero' || false
    ! job_actions "${example}" record | grep -q 'trivy' || false
    ! job_lines "${example}" build | grep -q 'trivy image ' || false
    ! job_lines "${example}" record | grep -q 'trivy image ' || false
  done
}

@test "each image build example builds for the architectures IMAGE_PLATFORMS lists, and names them nowhere else" {
  local example
  for example in $(build_examples); do
    grep -qx '  IMAGE_PLATFORMS: linux/amd64,linux/arm64' "${example}"
    job_lines "${example}" build | grep -qF 'docker buildx build --platform "${IMAGE_PLATFORMS}" --push'
    [ "$(grep -c 'linux/arm64' "${example}")" -eq 1 ]
  done
}

@test "each image build example checks IMAGE_PLATFORMS first, and refuses a list it would not build and scan as written" {
  local example script list
  for example in $(build_examples); do
    [ "$(job_lines "${example}" build | awk '/^      - / { print; exit }')" = '      - name: Check the architectures to build' ]
    script="$(step_script "${example}" 'Check the architectures to build')"
    [ -n "${script}" ]
    for list in linux/amd64 linux/amd64,linux/arm64 linux/arm/v7,linux/arm64; do
      IMAGE_PLATFORMS="${list}" run bash -eo pipefail -c "${script}"
      [ "${status}" -eq 0 ] || { echo "refused '${list}'"; false; }
    done
    for list in "" "linux/amd64, linux/arm64" "linux/amd64," ",linux/amd64" "linux/amd64,,linux/arm64" amd64 "Linux/AMD64" $'linux/amd64\nlinux/arm64'; do
      IMAGE_PLATFORMS="${list}" run bash -eo pipefail -c "${script}"
      [ "${status}" -eq 1 ] || { echo "accepted '${list}'"; false; }
      [[ "${output}" == *"::error::IMAGE_PLATFORMS must list one or more platforms"* ]] || false
    done
  done
}

@test "each image build example keeps one Trivy report of the pushed image for each architecture" {
  local example script
  fake_trivy
  for example in $(build_examples); do
    script="$(step_script "${example}" 'Scan each architecture')"
    [ -n "${script}" ]
    : > "${TRIVY_LOG}"
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" IMAGE_PLATFORMS=linux/amd64,linux/arm64 PUSHED=ghcr.io/o/r@sha256:abc \
      run bash -eo pipefail -c "${script}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${TRIVY_LOG}")" = "$(printf '%s\n' \
      "image --platform linux/amd64 --format json --output ${BATS_TEST_TMPDIR}/scan/trivy-linux-amd64.json ghcr.io/o/r@sha256:abc" \
      "image --platform linux/arm64 --format json --output ${BATS_TEST_TMPDIR}/scan/trivy-linux-arm64.json ghcr.io/o/r@sha256:abc")" ]
    job_lines "${example}" scan | grep -qxF '          PUSHED: ${{ needs.build.outputs.pushed }}'
    job_lines "${example}" scan | grep -qxF '          path: ${{ runner.temp }}/scan'
  done
}

@test "each image build example keeps no reports when the scan of one architecture fails" {
  local example script
  fake_trivy
  for example in $(build_examples); do
    script="$(step_script "${example}" 'Scan each architecture')"
    : > "${TRIVY_LOG}"
    TRIVY_FAILS_ON=linux/amd64 RUNNER_TEMP="${BATS_TEST_TMPDIR}" IMAGE_PLATFORMS=linux/amd64,linux/arm64 PUSHED=ghcr.io/o/r@sha256:abc \
      run bash -eo pipefail -c "${script}"
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${TRIVY_LOG}")" -eq 1 ]
    # The step fails before the upload, which has no condition of its own, so the record job of the example with no account does not run.
    ! job_lines "${example}" scan | grep -B2 -A1 'actions/upload-artifact@' | grep -q '^        if:' || false
    [ "$(job_lines "${example}" scan | grep -n -m1 '      - name: Scan each architecture' | cut -d: -f1)" -lt "$(job_lines "${example}" scan | grep -n -m1 'actions/upload-artifact@' | cut -d: -f1)" ]
  done
}

@test "each image build example gives record-image the report of each architecture, one per line" {
  local example script delimiter
  for example in $(build_examples); do
    script="$(step_script "${example}" 'List the scan report of each architecture')"
    [ -n "${script}" ]
    : > "${BATS_TEST_TMPDIR}/output"
    RUNNER_TEMP=/tmp/runner IMAGE_PLATFORMS=linux/amd64,linux/arm64 GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output" \
      run bash -eo pipefail -c "${script}"
    [ "${status}" -eq 0 ]
    delimiter="$(head -1 "${BATS_TEST_TMPDIR}/output")"
    [[ "${delimiter}" =~ ^lines\<\<[0-9a-f]{32}$ ]] || false
    [ "$(cat "${BATS_TEST_TMPDIR}/output")" = "$(printf '%s\n' "${delimiter}" \
      'trivy /tmp/runner/scan/trivy-linux-amd64.json' 'trivy /tmp/runner/scan/trivy-linux-arm64.json' "${delimiter#lines<<}")" ]
    grep -B1 'name: List the scan report of each architecture' "${example}" | grep -qx '      - id: scan-reports'
    grep -qxF '          scan-reports: ${{ steps.scan-reports.outputs.lines }}' "${example}"
  done
}

@test "the governed image build example records the image after the build and scan, then closes the build run of that application" {
  local example="${REPO_ROOT}/examples/image/governed-build.yml"
  grep -qE '^    needs: \[build, scan\]$' "${example}"
  [ "$(job_actions "${example}" record | grep '^ilterohq/' | tr '\n' ' ')" = "ilterohq/iltero-actions/setup ilterohq/iltero-actions/record-image ilterohq/iltero-actions/close " ]
  [ "$(grep -cE '^          application: \$\{\{ env\.APPLICATION \}\}$' "${example}")" -eq 2 ]
}

@test "the image build example with no account records the image after the build and scan, with no application, server, run or artifact store" {
  local example="${REPO_ROOT}/examples/image/build.yml"
  grep -qE '^    needs: \[build, scan\]$' "${example}"
  [ "$(job_actions "${example}" record | grep '^ilterohq/' | tr '\n' ' ')" = "ilterohq/iltero-actions/setup ilterohq/iltero-actions/record-image " ]
  ! grep -qE 'application:|APPLICATION|ILTERO_API_URL|id-token|store-records:' "${example}" || false
}

@test "each image build example scans and reads the index of the pushed image, by its digest" {
  local example
  for example in $(build_examples); do
    grep -qF 'docker buildx imagetools inspect --raw "${PUSHED}"' "${example}"
    grep -qF 'echo "pushed=${repository}@${digest}"' "${example}"
  done
}

@test "each image build example records the files its build and scan jobs wrote" {
  local example
  for example in $(build_examples); do
    grep -qF 'build-metadata: ${{ runner.temp }}/build/metadata.json' "${example}"
    grep -qF 'image-index: ${{ runner.temp }}/build/index.json' "${example}"
    [ "$(grep -cE '^          name: image-(build|scan)$' "${example}")" -eq 4 ]
  done
}

@test "each image build example builds from the Git repository at the pushed commit, so the build names its commit" {
  local example
  for example in $(build_examples); do
    grep -qF '"${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git#${GITHUB_SHA}"' "${example}"
  done
}

@test "each image build example stops when the build metadata names no image digest" {
  local example
  for example in $(build_examples); do
    grep -qF '[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {' "${example}"
  done
}

@test "the image build example with no account checks the build as advice, since a local check cannot confirm its commit" {
  grep -A7 'iltero-actions/record-image@' "${REPO_ROOT}/examples/image/build.yml" | grep -qx '          advisory: true'
  [ "$(grep -c '^          advisory: true$' "${REPO_ROOT}/examples/image/build.yml")" -eq 1 ]
}

@test "the governed image build example never checks as advice, since the run decides" {
  ! grep -q 'advisory:' "${REPO_ROOT}/examples/image/governed-build.yml" || false
}

@test "each image build example gives the build the job's token only in a private repository" {
  local example
  for example in $(build_examples); do
    grep -qxF "          GIT_AUTH_TOKEN: \${{ github.event.repository.private && github.token || '' }}" "${example}"
    grep -qxF '          [[ -z "${GIT_AUTH_TOKEN}" ]] || source_access=(--secret "id=GIT_AUTH_TOKEN,env=GIT_AUTH_TOKEN")' "${example}"
    [ "$(grep -c -- '--secret' "${example}")" -eq 1 ]
  done
}

@test "the governed image build example scans each architecture once and never stops on findings, since Iltero Platform decides" {
  local example="${REPO_ROOT}/examples/image/governed-build.yml"
  [ "$(grep -c 'trivy image ' "${example}")" -eq 1 ]
  ! grep -qE 'FAIL_ON_SCAN_SEVERITIES|--exit-code' "${example}" || false
}

@test "the image build example with no account stops the workflow on findings at the chosen severities, in any architecture, after the reports are kept" {
  local example="${REPO_ROOT}/examples/image/build.yml" gate
  grep -qE '^  FAIL_ON_SCAN_SEVERITIES: [A-Z,]*$' "${example}"
  # The reports' scan never stops the job; the last step of the scan job does.
  ! step_script "${example}" 'Scan each architecture' | grep -q -- '--exit-code' || false
  [ "$(job_lines "${example}" scan | awk '/^      - / { last = $0 } END { print last }')" = '      - name: Stop on vulnerabilities at the chosen severities' ]
  grep -A1 'name: Stop on vulnerabilities at the chosen severities' "${example}" | grep -qxF "        if: \${{ env.FAIL_ON_SCAN_SEVERITIES != '' }}"
  gate="$(step_script "${example}" 'Stop on vulnerabilities at the chosen severities')"
  [ -n "${gate}" ]
  fake_trivy
  # Every architecture is checked, vulnerabilities only, with the databases the reports were read with.
  IMAGE_PLATFORMS=linux/amd64,linux/arm64 FAIL_ON_SCAN_SEVERITIES=CRITICAL,HIGH PUSHED=ghcr.io/o/r@sha256:abc \
    run bash -eo pipefail -c "${gate}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${TRIVY_LOG}")" = "$(printf '%s\n' \
    'image --platform linux/amd64 --scanners vuln --severity CRITICAL,HIGH --exit-code 1 --skip-db-update --skip-java-db-update ghcr.io/o/r@sha256:abc' \
    'image --platform linux/arm64 --scanners vuln --severity CRITICAL,HIGH --exit-code 1 --skip-db-update --skip-java-db-update ghcr.io/o/r@sha256:abc')" ]
  # A finding in one architecture fails the step, after every architecture is checked.
  : > "${TRIVY_LOG}"
  TRIVY_FAILS_ON=linux/amd64 IMAGE_PLATFORMS=linux/amd64,linux/arm64 FAIL_ON_SCAN_SEVERITIES=CRITICAL PUSHED=ghcr.io/o/r@sha256:abc \
    run bash -eo pipefail -c "${gate}"
  [ "${status}" -eq 1 ]
  [ "$(wc -l < "${TRIVY_LOG}")" -eq 2 ]
}

@test "the image build example with no account refuses a severity list that Trivy would not read as written" {
  local example="${REPO_ROOT}/examples/image/build.yml" check list
  [ "$(awk '/^  scan:$/ { inside = 1; next } /^  [a-z-]+:$/ { inside = 0 } inside && /^      - / { print; exit }' "${example}")" = '      - name: Check the severities that stop the workflow' ]
  check="$(awk '/name: Check the severities that stop the workflow/ { inside = 1; next } inside && /^        run: \|$/ { body = 1; next } body && /^      - / { exit } body { sub(/^          /, ""); print }' "${example}")"
  for list in "" CRITICAL CRITICAL,HIGH UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL; do
    FAIL_ON_SCAN_SEVERITIES="${list}" run bash -euo pipefail -c "${check}"
    [ "${status}" -eq 0 ] || { echo "refused '${list}'"; false; }
  done
  for list in CRITCAL "CRITICAL, HIGH" critical "CRITICAL," ",HIGH" "HIGH;CRITICAL"; do
    FAIL_ON_SCAN_SEVERITIES="${list}" run bash -euo pipefail -c "${check}"
    [ "${status}" -eq 1 ] || { echo "accepted '${list}'"; false; }
    [[ "${output}" == *"::error::FAIL_ON_SCAN_SEVERITIES must be empty"* ]] || false
  done
}

@test "the image build example with no account records the image also when the scan stopped the workflow, once the reports are kept" {
  job_lines "${REPO_ROOT}/examples/image/build.yml" record \
    | grep -qxF "    if: \${{ !cancelled() && needs.build.result == 'success' && needs.scan.outputs.report-kept == 'true' }}"
  job_lines "${REPO_ROOT}/examples/image/build.yml" scan \
    | grep -qxF "      report-kept: \${{ steps.report.outcome == 'success' }}"
  grep -A1 '^      - id: report$' "${REPO_ROOT}/examples/image/build.yml" | grep -q 'uses: actions/upload-artifact@'
}

@test "each image build example records the build's plan stage" {
  local example
  for example in $(build_examples); do
    grep -A2 'iltero-actions/record-image@' "${example}" | grep -qx '          stage: plan'
  done
}

# --- image/deployment --------------------------------------------------------

# Prints each line of a deployment example that records a stage or deploys,
# in order: the stage's name, or "deploy" and "rollout".
deployment_order() {
  awk '
    /^          stage: / { print $2 }
    /kubectl .* set image / { print "deploy" }
    /kubectl .* rollout status / { print "rollout" }
  ' "$1"
}

@test "the deployment examples check the image before they deploy, report it after, and check the pods after the rollout" {
  local example
  for example in $(deployment_examples); do
    [ "$(deployment_order "${example}" | tr '\n' ' ')" = "pre_deploy deploy post_deploy rollout post_verify " ]
  done
}

@test "the deployment example needs no account, and sends nothing to Iltero" {
  local example="${REPO_ROOT}/examples/image/deployment.yml"
  ! grep -qE 'iltero-actions/(open|close)@|ILTERO_API_URL|application:|store-records:' "${example}" || false
}

@test "the deployment examples' deploy jobs may only read the repository and get their identity token" {
  local example
  for example in $(deployment_examples); do
    [ "$(job_permissions "${example}" deploy)" = "$(printf '%s\n' 'contents: read' 'id-token: write')" ]
  done
}

@test "the deployment example checks the pre-deploy gate as advice, since a local record reads no approvals" {
  grep -A5 'iltero-actions/record-image@' "${REPO_ROOT}/examples/image/deployment.yml" | grep -qx '          advisory: true'
  [ "$(grep -c '^          advisory: true$' "${REPO_ROOT}/examples/image/deployment.yml")" -eq 1 ]
}

@test "the deployment examples read the workload, its pods, its ReplicaSets and the workload again, in that order" {
  local example
  for example in $(deployment_examples); do
    [ "$(grep -oE '> "\$\{RUNNER_TEMP\}/[a-z-]+\.json"' "${example}" | tr '\n' ' ')" \
      = '> "${RUNNER_TEMP}/workload-before.json" > "${RUNNER_TEMP}/pods.json" > "${RUNNER_TEMP}/pod-owners.json" > "${RUNNER_TEMP}/workload-after.json" ' ]
    [ "$(grep -c 'kubectl get --raw ' "${example}")" -eq 4 ]
  done
}

@test "the deployment examples keep the readings in the runner's temporary directory, and never upload them" {
  local example
  for example in $(deployment_examples); do
    ! grep -E '^          (workload-before-pods-listing|pods|pod-owners|workload-after-pods-listing): ' "${example}" | grep -v 'runner.temp' || false
    ! grep -qE 'upload-artifact|s3 (cp|sync)' "${example}" || false
  done
}

@test "the deployment examples report the image the workload names after the deployment, not the input they were given" {
  local example
  for example in $(deployment_examples); do
    grep -A2 '^          stage: post_deploy$' "${example}" | grep -qxF '          image: ${{ steps.deployed.outputs.image }}'
    grep -qF '[[ "${image}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {' "${example}"
  done
}

@test "the deployment examples stop when the cluster names no uid" {
  local example
  for example in $(deployment_examples); do
    grep -qF '[[ "${cluster_id}" =~ ^[0-9a-f-]{36}$ ]] || {' "${example}"
  done
}

# --- image/governed-deployment -----------------------------------------------

@test "the governed deployment example waits for the rollout once the image went out, also after a failed post_deploy" {
  awk '/^      - id: rollout$/ { inside = 1; next } inside && /^      - / { exit } inside { print }' \
    "${REPO_ROOT}/examples/image/governed-deployment.yml" | grep -qxF "        if: \${{ !cancelled() && steps.deploy.outcome == 'success' }}"
}

@test "the governed deployment example checks the pods after a failed rollout too" {
  local example="${REPO_ROOT}/examples/image/governed-deployment.yml"
  grep -qF "if: \${{ !cancelled() && steps.rollout.outcome != 'skipped' }}" "${example}"
  grep -B1 'iltero-actions/record-image@' "${example}" | grep -qF "if: \${{ !cancelled() && steps.read.outcome == 'success' }}"
}

@test "the governed deployment example keeps every stage's record in the run's artifact store, after the cloud credentials are set" {
  local example="${REPO_ROOT}/examples/image/governed-deployment.yml"
  [ "$(grep -c '^          store-records: true$' "${example}")" -eq 3 ]
  [ "$(grep -n 'configure-aws-credentials@' "${example}" | cut -d: -f1)" -lt "$(grep -n 'stage: pre_deploy' "${example}" | cut -d: -f1)" ]
}

@test "the governed deployment example names the application at every deployment stage" {
  local example="${REPO_ROOT}/examples/image/governed-deployment.yml"
  [ "$(grep -A3 -E '^          stage: (pre_deploy|post_deploy|post_verify)$' "${example}" | grep -c '^          application: \${{ env.APPLICATION }}$')" -eq 3 ]
}

@test "the governed deployment example deploys in the GitHub deployment environment of the environment it records" {
  local example="${REPO_ROOT}/examples/image/governed-deployment.yml"
  [ "$(awk '/^  deploy:$/ { inside = 1; next } /^  [a-z-]+:$/ { inside = 0 } inside && /^    environment: / { print $2 }' "${example}")" \
    = "$(job_environment "${example}" deploy)" ]
  [ "$(job_environment "${example}" deploy)" = production ]
}

@test "the governed deployment example never checks as advice, since the run decides" {
  ! grep -q 'advisory:' "${REPO_ROOT}/examples/image/governed-deployment.yml" || false
}

@test "the governed deployment example closes the image deploy run of its application and environment" {
  local close
  close="$(grep -A3 'iltero-actions/close@' "${REPO_ROOT}/examples/image/governed-deployment.yml")"
  grep -qxF '          application: ${{ env.APPLICATION }}' <<< "${close}"
  grep -qx '          environment: production' <<< "${close}"
}
