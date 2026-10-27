#!/usr/bin/env bats
#
# Tests for scripts/comment.sh, the body of the `comment` action.

load test_helper


setup() {
  make_runner
  export GITHUB_EVENT_NAME="pull_request"
  export GITHUB_REPOSITORY="octo/stack"
  export HEAD_REPOSITORY="octo/stack"
  export GITHUB_TOKEN="workflow-token"
  # A person, not the CI run's own actor: the action posts nothing for Dependabot.
  export GITHUB_ACTOR="octocat"
  export PR_NUMBER="7"
  export GITHUB_WORKFLOW_REF="octo/stack/.github/workflows/preview.yml@refs/pull/7/merge"
  MARKER="$(marker_for "${GITHUB_WORKFLOW_REF}")"
  COMMENT="${REPO_ROOT}/scripts/comment.sh"
  COMMENTS="${BATS_TEST_TMPDIR}/comments.json"
  API_LOG="${BATS_TEST_TMPDIR}/api.log"
  BODY="${BATS_TEST_TMPDIR}/comment.md"
  echo '[]' > "${COMMENTS}"
  : > "${API_LOG}"
  printf '## Iltero preview: production\n' > "${BODY}"
}

# Prints the marker the action writes for the default artifact and a
# workflow reference.
marker_for() {
  local workflow
  workflow="$(printf '%s' "${1%%@*}" | sha256sum | cut -c1-12)"
  echo "<!-- iltero-preview:iltero-preview-comment:${workflow} -->"
}

teardown() {
  [[ -z "${FAKE_PID:-}" ]] || { kill "${FAKE_PID}" && wait "${FAKE_PID}"; } 2> /dev/null || true
}

# Starts the stand-in for GitHub's API and points GITHUB_API_URL at it.
start_fake_github() {
  local port_file="${BATS_TEST_TMPDIR}/port"
  python3 "${REPO_ROOT}/tests/fake_github.py" "${port_file}" "${COMMENTS}" "${API_LOG}" &
  FAKE_PID=$!
  local tries=0
  until [[ -s "${port_file}" ]]; do
    tries=$((tries + 1))
    [[ "${tries}" -lt 50 ]] || { echo "the fake API did not start"; return 1; }
    sleep 0.1
  done
  GITHUB_API_URL="http://127.0.0.1:$(cat "${port_file}")"
  export GITHUB_API_URL
}

# Writes COUNT comments by other people, then the given comments, as JSON.
comments() {
  local count="$1"
  shift
  python3 - "${count}" "$@" > "${COMMENTS}" << 'PY'
import json, sys
count, extra = int(sys.argv[1]), sys.argv[2:]
items = [{"id": 1000 + i, "user": {"login": "someone"}, "body": "looks good"} for i in range(count)]
for entry in extra:
    comment_id, login, body = entry.split("|", 2)
    items.append({"id": int(comment_id), "user": {"login": login}, "body": body})
print(json.dumps(items))
PY
}

@test "check refuses pull_request_target and workflow_run events" {
  local event
  for event in pull_request_target workflow_run; do
    GITHUB_EVENT_NAME="${event}" run "${COMMENT}" check iltero-preview-comment
    [ "${status}" -eq 1 ]
  done
}

@test "check refuses events other than pull_request" {
  GITHUB_EVENT_NAME=push run "${COMMENT}" check iltero-preview-comment
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"runs only on pull_request events"* ]]
}

@test "an artifact name that could end the marker is refused" {
  run "${COMMENT}" check 'x -->'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Invalid artifact name"* ]]
}

@test "post creates the comment, starting with its marker, when there is none" {
  start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  grep -q "^POST /repos/octo/stack/issues/7/comments " "${API_LOG}"
  grep -qF "\"body\": \"${MARKER}\\n## Iltero preview: production\\n\"" "${API_LOG}"
}

@test "post updates its earlier comment, found on a later page" {
  comments 100 "4242|github-actions[bot]|${MARKER}"$'\n'"old"
  start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  grep -q "^GET /repos/octo/stack/issues/7/comments?per_page=100&page=2 " "${API_LOG}"
  grep -q "^PATCH /repos/octo/stack/issues/comments/4242 " "${API_LOG}"
  ! grep -q "^POST" "${API_LOG}" || false
}

@test "post leaves alone a comment with another marker or by someone else" {
  comments 0 "1|github-actions[bot]|<!-- iltero-preview:other -->" "2|someone|${MARKER}"
  start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  ! grep -q "^PATCH" "${API_LOG}" || false
  grep -q "^POST /repos/octo/stack/issues/7/comments " "${API_LOG}"
}

@test "post calls only the issue comments API, to create or to update" {
  start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  comments 0 "4242|github-actions[bot]|${MARKER}"
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  grep -q "^POST" "${API_LOG}"
  grep -q "^PATCH" "${API_LOG}"
  ! grep -vE '^[A-Z]+ /repos/octo/stack/issues/(7/comments[? ]|comments/[0-9]+ )' "${API_LOG}" || false
}

@test "each workflow file keeps its own comment, whatever the branch" {
  comments 0 "4242|github-actions[bot]|$(marker_for "octo/stack/.github/workflows/other.yml@refs/pull/7/merge")"
  start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  ! grep -q "^PATCH" "${API_LOG}" || false
  comments 0 "4242|github-actions[bot]|$(marker_for "octo/stack/.github/workflows/preview.yml@refs/heads/other")"
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  grep -q "^PATCH /repos/octo/stack/issues/comments/4242 " "${API_LOG}"
}

@test "post sends nothing for a pull request from a fork, and says so" {
  start_fake_github
  HEAD_REPOSITORY="someone/stack" run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"comes from a fork"* ]]
  [ ! -s "${API_LOG}" ]
}

@test "post sends nothing for a pull request from Dependabot, and says so" {
  start_fake_github
  GITHUB_ACTOR="dependabot[bot]" run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"comes from Dependabot"* ]]
  [ ! -s "${API_LOG}" ]
}

@test "post fails when the token may not comment, and names the permission" {
  FAKE_STATUS=403 start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HTTP 403"*"pull-requests: write"* ]]
}

@test "post fails on any other refusal, and shows GitHub's answer" {
  FAKE_STATUS=422 start_fake_github
  run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"HTTP 422"*"fake failure"* ]]
  [[ "${output}" != *"pull-requests: write"* ]]
}

@test "post refuses a pull request number that is not a number" {
  PR_NUMBER="7/../../x" run "${COMMENT}" post iltero-preview-comment "${BODY}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"not a pull request number"* ]]
}

@test "post fails when the comment file is missing" {
  run "${COMMENT}" post iltero-preview-comment "${BATS_TEST_TMPDIR}/none.md"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"comment file is missing"* ]]
}
