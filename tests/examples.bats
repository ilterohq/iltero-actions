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

@test "the governed workflow grants only contents: read and id-token: write" {
  run grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/greenfield.yml"
  [ "${status}" -eq 0 ]
  ! grep -E '^      [a-z-]+: (read|write)( #.*)?$' "${REPO_ROOT}/examples/greenfield.yml" | grep -vE '^      (contents: read|id-token: write)( #.*)?$' || false
}

@test "the workflow that needs no account never opens a run and never passes a run" {
  ! grep -qE 'iltero-actions/(open|close)@|run-id:|pins-digest:|ILTERO_API_URL' "${REPO_ROOT}/examples/deploy.yml" || false
  grep -q 'iltero-actions/verify@' "${REPO_ROOT}/examples/deploy.yml"
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
