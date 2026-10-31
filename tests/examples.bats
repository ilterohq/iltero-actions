#!/usr/bin/env bats
#
# The reference workflows under examples/ are what repository owners copy.
# Every action, input and output they use must exist.

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

@test "every step output an example reads is declared by that step's action" {
  local file reference id output action
  for file in $(examples); do
    for reference in $(grep -oE 'steps\.[a-z-]+\.outputs\.[a-z-]+' "${file}" | sort -u); do
      id="$(echo "${reference}" | cut -d. -f2)"
      output="$(echo "${reference}" | cut -d. -f4)"
      action="$(iltero_steps "${file}" | awk -v id="${id}" '$1 == id { print $2; exit }')"
      [ -n "${action}" ] || { echo "${file}: no Iltero step with id '${id}'"; false; }
      declared "${action}" outputs | grep -qx "${output}" || { echo "${file}: ${action} has no output '${output}'"; false; }
    done
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
  for file in greenfield.yml record-iac.yml; do
    ! grep -qE 'iltero-actions/open@|run-id|run-settings-digest|^    outputs:' "${REPO_ROOT}/examples/${file}" || false
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

@test "the governed workflow closes each run only after its deploy job succeeded" {
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
    ! grep -nE 's3 (cp|sync)|s3api|upload-artifact' "${file}" || false
  done
}

@test "the record-iac example never applies a refresh-only plan" {
  ! grep -E 'terraform apply[^#]*-refresh-only' "${REPO_ROOT}/examples/record-iac.yml" || false
}

@test "the record-iac example does not have setup install a second Terraform" {
  grep -A2 'iltero-actions/setup@' "${REPO_ROOT}/examples/record-iac.yml" | grep -qE '^          install-terraform: false( #.*)?$'
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
