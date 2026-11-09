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
  ls "${REPO_ROOT}"/examples/*.yml
}

@test "the reference workflows exist" {
  [ -f "${REPO_ROOT}/examples/greenfield.yml" ]
  [ -f "${REPO_ROOT}/examples/preview.yml" ]
  [ -f "${REPO_ROOT}/examples/deploy.yml" ]
  [ -f "${REPO_ROOT}/examples/record-iac.yml" ]
  [ -f "${REPO_ROOT}/examples/record-image.yml" ]
  [ -f "${REPO_ROOT}/examples/record-image-deployment.yml" ]
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
        run_step "${file}" "${id}" | grep -qE "echo \"${output}=.*>> \"\\$\\{GITHUB_OUTPUT\}\"$" \
          || { echo "${file}: no run step '${id}' writes output '${output}'"; false; }
        continue
      fi
      declared "${action}" outputs | grep -qx "${output}" || { echo "${file}: ${action} has no output '${output}'"; false; }
    done < <(grep -oE 'steps\.[a-z-]+\.outputs\.[a-z-]+' "${file}" | sort -u)
  done
}

@test "every Iltero action in an example is pinned to the same commit" {
  local file
  for file in $(examples); do
    run bash -c "grep -oE 'ilterohq/iltero-actions/[a-z-]+@[0-9a-f]{40}' '${file}' | cut -d@ -f2 | sort -u | wc -l"
    [ "${output//[[:space:]]/}" = "1" ]
  done
}

@test "the governed workflows grant only contents: read and id-token: write" {
  local file
  for file in greenfield.yml record-iac.yml; do
    run grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/${file}"
    [ "${status}" -eq 0 ]
    ! grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/${file}" | grep -vE '^      (contents: read|id-token: write)( #.*)?$' || false
  done
}

@test "the workflow that needs no account never opens a run and never passes a run" {
  ! grep -qE 'iltero-actions/(open|close)@|run-id:|run-settings-digest:|ILTERO_API_URL' "${REPO_ROOT}/examples/deploy.yml" || false
  grep -q 'iltero-actions/verify@' "${REPO_ROOT}/examples/deploy.yml"
}

@test "the governed workflows never open a run or pass a run between jobs" {
  local file
  for file in greenfield.yml record-iac.yml record-image.yml; do
    ! grep -qE 'iltero-actions/open@|run-id|run-settings-digest' "${REPO_ROOT}/examples/${file}" || false
  done
  # The image example's job outputs carry only the image's reference.
  for file in greenfield.yml record-iac.yml; do
    ! grep -qE '^    outputs:' "${REPO_ROOT}/examples/${file}" || false
  done
  [ "$(awk '/^    outputs:$/ { inside = 1; next } inside && !/^      / { inside = 0 } inside { print $1 }' "${REPO_ROOT}/examples/record-image.yml" | tr '\n' ' ')" = "image: pushed: " ]
}

# Prints the environment input of the steps of one job of a workflow.
job_environment() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /^          environment: / { print $2 }
  ' "$1" | sort -u
}

@test "each close job of the governed workflows closes its deploy job's environment" {
  local greenfield="${REPO_ROOT}/examples/greenfield.yml" record_iac="${REPO_ROOT}/examples/record-iac.yml"
  [ "$(job_environment "${greenfield}" close-staging)" = "$(job_environment "${greenfield}" deploy-staging)" ]
  [ "$(job_environment "${greenfield}" close-production)" = "$(job_environment "${greenfield}" deploy-production)" ]
  [ "$(job_environment "${record_iac}" close)" = "$(job_environment "${record_iac}" deploy)" ]
  [ "$(job_environment "${greenfield}" close-staging)" = staging ]
  [ "$(job_environment "${record_iac}" close)" = production ]
}

# Prints the permission lines of one job of a workflow.
job_permissions() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /^      [a-z-]+: (read|write)( #.*)?$/ { sub(/ #.*/, ""); sub(/^ +/, ""); print }
  ' "$1"
}

@test "the preview workflow runs only on pull requests and holds no identity token" {
  grep -qE '^  pull_request:$' "${REPO_ROOT}/examples/preview.yml"
  ! grep -qE 'pull_request_target|workflow_run|id-token' "${REPO_ROOT}/examples/preview.yml" || false
}

@test "the preview job may only read the repository" {
  [ "$(job_permissions "${REPO_ROOT}/examples/preview.yml" preview)" = "contents: read" ]
}

@test "the comment job may only write pull requests, and runs no code from the pull request" {
  [ "$(job_permissions "${REPO_ROOT}/examples/preview.yml" comment)" = "pull-requests: write" ]
  [ "$(awk '/^  comment:$/ { inside = 1; next } /^  [a-z-]+:$/ { inside = 0 } inside && /uses:/ { sub(/.*uses: /, ""); sub(/@.*/, ""); print }' "${REPO_ROOT}/examples/preview.yml")" = "ilterohq/iltero-actions/comment" ]
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
  ' "${REPO_ROOT}/examples/greenfield.yml")"
  [ "${jobs}" = "$(printf '%s\n' 'close-staging deploy-staging -' 'close-production deploy-production -')" ]
  jobs="$(awk '
    function flush() { if (job == "close") print job, needs, (cond == "" ? "-" : cond); job = ""; needs = ""; cond = "" }
    /^  [a-z-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
    /^    needs: / { needs = $2 }
    /^    if: / { cond = $0 }
    END { flush() }
  ' "${REPO_ROOT}/examples/record-iac.yml")"
  [ "${jobs}" = "close deploy -" ]
}

# Prints the stage of each record-iac step of the record-iac example, in order.
record_iac_events() {
  awk '/uses: ilterohq\/iltero-actions\/record-iac@/ { inside = 1; next } inside && /^          stage: / { print $2; inside = 0 }' \
    "${REPO_ROOT}/examples/record-iac.yml"
}

@test "the record-iac example records plan, pre_deploy, post_deploy and post_verify, in that order, as production needs" {
  [ "$(record_iac_events | tr '\n' ' ')" = "plan pre_deploy post_deploy post_verify " ]
}

@test "the record-iac example reads the deployed resources twice with refresh-only plans, a minute apart" {
  local example="${REPO_ROOT}/examples/record-iac.yml"
  [ "$(grep -c 'terraform plan -input=false -refresh-only ' "${example}")" -eq 2 ]
  grep -A3 'network-first.json"$' "${example}" | grep -qx '          sleep 60'
}

@test "no example uploads or keeps the readings of the deployed resources" {
  local file
  for file in "${REPO_ROOT}"/examples/*.yml; do
    ! grep -nE 'readings-directory|network-(first|second)\.json' "${file}" | grep -vE 'terraform show -json|^[0-9]+:            \$\{\{ runner\.temp \}\}/network-(first|second)\.json$' || false
    # The image example deploys nothing, and uploads only its build and scan files.
    [ "${file##*/}" = record-image.yml ] || ! grep -nE 's3 (cp|sync)|s3api|upload-artifact' "${file}" || false
  done
}

@test "the record-iac example never applies a refresh-only plan" {
  ! grep -E 'terraform apply[^#]*-refresh-only' "${REPO_ROOT}/examples/record-iac.yml" || false
}

@test "the close jobs do not have setup install Terraform" {
  local file
  for file in greenfield.yml record-iac.yml; do
    [ "$(grep -c 'iltero-actions/close@' "${REPO_ROOT}/examples/${file}")" -eq "$(grep -B3 'iltero-actions/close@' "${REPO_ROOT}/examples/${file}" | grep -c '^          install-terraform: false')" ]
  done
}

@test "every deployment stage of the image example names the environment" {
  local example="${REPO_ROOT}/examples/record-image-deployment.yml"
  [ "$(grep -cE '^          stage: (pre_deploy|post_deploy|post_verify)$' "${example}")" -eq 3 ]
  [ "$(grep -A3 -E '^          stage: (pre_deploy|post_deploy|post_verify)$' "${example}" | grep -c '^          environment: production$')" -eq 3 ]
}

@test "the deployment example reports the image after a failed deployment too" {
  local example="${REPO_ROOT}/examples/record-image-deployment.yml"
  grep -qF "if: \${{ !cancelled() && steps.deploy.outcome != 'skipped' }}" "${example}"
  grep -qF "if: \${{ !cancelled() && steps.deployed.outcome == 'success' }}" "${example}"
}

@test "the record-iac example does not have setup install a second Terraform" {
  grep -A2 'iltero-actions/setup@' "${REPO_ROOT}/examples/record-iac.yml" | grep -qE '^          install-terraform: false( #.*)?$'
}

@test "the record-iac example keeps every stage's record in the run's artifact store, after the cloud credentials are set" {
  local example="${REPO_ROOT}/examples/record-iac.yml"
  [ "$(grep -c '^          store-records: true$' "${example}")" -eq "$(grep -c 'iltero-actions/record-iac@' "${example}")" ]
  [ "$(grep -n -m1 'configure-aws-credentials@' "${example}" | cut -d: -f1)" -lt "$(grep -n -m1 'store-records: true' "${example}" | cut -d: -f1)" ]
}

@test "the record-iac example records the apply also when the state could not be read" {
  local example="${REPO_ROOT}/examples/record-iac.yml"
  grep -qF "state: \${{ steps.state.outcome == 'success' && format('{0}/network-state.json', runner.temp) || '' }}" "${example}"
  grep -qxF "          state-unreadable: \${{ steps.state.outcome == 'failure' }}" "${example}"
  grep -qx "      - id: state" "${example}"
}

@test "the record-iac example records post_deploy also after a failed apply" {
  grep -B1 'iltero-actions/record-iac@' "${REPO_ROOT}/examples/record-iac.yml" | grep -qF "if: \${{ !cancelled() && steps.apply.outcome != 'skipped' }}"
}

@test "the record-iac example keeps Terraform's files out of the checked-out repository" {
  ! grep -E -- '-out=|> ' "${REPO_ROOT}/examples/record-iac.yml" | grep -v RUNNER_TEMP || false
  ! grep -E '^          (plan|saved-plan|apply-log|state): ' "${REPO_ROOT}/examples/record-iac.yml" | grep -v 'runner.temp' || false
  grep -q '^          refresh-plans: |$' "${REPO_ROOT}/examples/record-iac.yml"
  ! grep -A2 '^          refresh-plans: |$' "${REPO_ROOT}/examples/record-iac.yml" | tail -n +2 | grep -v 'runner.temp' || false
}

# --- record-image ------------------------------------------------------------

@test "the record-image example's build job may only read the source and push the image" {
  [ "$(job_permissions "${REPO_ROOT}/examples/record-image.yml" build)" = "$(printf '%s\n' 'contents: read' 'packages: write')" ]
}

@test "the record-image example's scanner may only pull the image, and holds no identity token" {
  [ "$(job_permissions "${REPO_ROOT}/examples/record-image.yml" scan)" = "packages: read" ]
}

@test "the record-image example's record job may only read the repository and get its identity token" {
  [ "$(job_permissions "${REPO_ROOT}/examples/record-image.yml" record)" = "$(printf '%s\n' 'contents: read' 'id-token: write')" ]
}

# Prints the actions one job of a workflow uses, one per line, without their commits.
job_actions() {
  awk -v job="$2" '
    /^  [a-z-]+:$/ { inside = ($1 == job ":") }
    inside && /uses: / { sub(/.*uses: /, ""); sub(/@.*/, ""); print }
  ' "$1"
}

@test "the record-image example runs the scanner only in the scan job, and Iltero only in the record job" {
  local example="${REPO_ROOT}/examples/record-image.yml"
  [ "$(job_actions "${example}" scan | grep -c '^aquasecurity/trivy-action$')" -eq 1 ]
  ! job_actions "${example}" build | grep -qE 'trivy|iltero' || false
  ! job_actions "${example}" scan | grep -q 'iltero' || false
  ! job_actions "${example}" record | grep -q 'trivy' || false
}

@test "the record-image example records the image after the build and scan, then closes the build run of that application" {
  local example="${REPO_ROOT}/examples/record-image.yml"
  grep -qE '^    needs: \[build, scan\]$' "${example}"
  [ "$(job_actions "${example}" record | grep '^ilterohq/' | tr '\n' ' ')" = "ilterohq/iltero-actions/setup ilterohq/iltero-actions/record-image ilterohq/iltero-actions/close " ]
  [ "$(grep -cE '^          application: \$\{\{ env\.APPLICATION \}\}$' "${example}")" -eq 2 ]
}

@test "the record-image example scans and reads the index of the pushed image, by its digest" {
  local example="${REPO_ROOT}/examples/record-image.yml"
  grep -qF 'image-ref: ${{ needs.build.outputs.pushed }}' "${example}"
  grep -qF 'docker buildx imagetools inspect --raw "${PUSHED}"' "${example}"
  grep -qF 'echo "pushed=${repository}@${digest}"' "${example}"
}

@test "the record-image example records the files its build and scan jobs wrote" {
  local example="${REPO_ROOT}/examples/record-image.yml"
  grep -qF 'build-metadata: ${{ runner.temp }}/build/metadata.json' "${example}"
  grep -qF 'image-index: ${{ runner.temp }}/build/index.json' "${example}"
  grep -qF 'scan-reports: trivy ${{ runner.temp }}/scan/trivy.json' "${example}"
  [ "$(grep -cE '^          name: image-(build|scan)$' "${example}")" -eq 4 ]
}

@test "the record-image example builds from the Git repository at the pushed commit, so the build names its commit" {
  grep -qF '"${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git#${GITHUB_SHA}"' "${REPO_ROOT}/examples/record-image.yml"
}

@test "the record-image example stops when the build metadata names no image digest" {
  grep -qF '[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || {' "${REPO_ROOT}/examples/record-image.yml"
}

@test "the record-image example records the build's plan stage" {
  grep -A2 'iltero-actions/record-image@' "${REPO_ROOT}/examples/record-image.yml" | grep -qx '          stage: plan'
}

# --- record-image-deployment -------------------------------------------------

# Prints each line of the deployment example that records a stage or deploys,
# in order: the stage's name, or "deploy" and "rollout".
deployment_order() {
  awk '
    /^          stage: / { print $2 }
    /kubectl .* set image / { print "deploy" }
    /kubectl .* rollout status / { print "rollout" }
  ' "${REPO_ROOT}/examples/record-image-deployment.yml"
}

@test "the deployment example checks the image before it deploys, reports it after, and checks the pods after the rollout" {
  [ "$(deployment_order | tr '\n' ' ')" = "pre_deploy deploy post_deploy rollout post_verify " ]
}

@test "the deployment example needs no account, and sends nothing to Iltero" {
  local example="${REPO_ROOT}/examples/record-image-deployment.yml"
  ! grep -qE 'iltero-actions/(open|close)@|ILTERO_API_URL|application:|store-records:' "${example}" || false
}

@test "the deployment example's job may only read the repository and get its identity token, for the deploy role" {
  [ "$(job_permissions "${REPO_ROOT}/examples/record-image-deployment.yml" deploy)" = "$(printf '%s\n' 'contents: read' 'id-token: write')" ]
}

@test "the deployment example checks the pre-deploy gate as advice, since a local record reads no approvals" {
  grep -A5 'iltero-actions/record-image@' "${REPO_ROOT}/examples/record-image-deployment.yml" | grep -qx '          advisory: true'
  [ "$(grep -c '^          advisory: true$' "${REPO_ROOT}/examples/record-image-deployment.yml")" -eq 1 ]
}

@test "the deployment example reads the workload, its pods, its ReplicaSets and the workload again, in that order" {
  [ "$(grep -oE '> "\$\{RUNNER_TEMP\}/[a-z-]+\.json"' "${REPO_ROOT}/examples/record-image-deployment.yml" | tr '\n' ' ')" \
    = '> "${RUNNER_TEMP}/workload-before.json" > "${RUNNER_TEMP}/pods.json" > "${RUNNER_TEMP}/pod-owners.json" > "${RUNNER_TEMP}/workload-after.json" ' ]
  [ "$(grep -c 'kubectl get --raw ' "${REPO_ROOT}/examples/record-image-deployment.yml")" -eq 4 ]
}

@test "the deployment example keeps the readings in the runner's temporary directory, and never uploads them" {
  local example="${REPO_ROOT}/examples/record-image-deployment.yml"
  ! grep -E '^          (workload-before-pods-listing|pods|pod-owners|workload-after-pods-listing): ' "${example}" | grep -v 'runner.temp' || false
  ! grep -qE 'upload-artifact|s3 (cp|sync)' "${example}" || false
}

@test "the deployment example reports the image the workload names after the deployment, not the input it was given" {
  local example="${REPO_ROOT}/examples/record-image-deployment.yml"
  grep -A2 '^          stage: post_deploy$' "${example}" | grep -qxF '          image: ${{ steps.deployed.outputs.image }}'
  grep -qF '[[ "${image}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {' "${example}"
}

@test "the deployment example stops when the cluster names no uid" {
  grep -qF '[[ "${cluster_id}" =~ ^[0-9a-f-]{36}$ ]] || {' "${REPO_ROOT}/examples/record-image-deployment.yml"
}
