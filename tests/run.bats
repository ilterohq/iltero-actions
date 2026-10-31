#!/usr/bin/env bats
#
# Tests for scripts/run.sh, the body of the `close` action.

load test_helper

setup() {
  make_runner
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export CLI_EXIT=0
  RUN="${REPO_ROOT}/scripts/run.sh"
  # A stand-in for the CLI that setup installs. It records its arguments.
  mkdir -p "${RUNNER_TEMP}/iltero-tools/venv/bin"
  ln -s "$(command -v python3)" "${RUNNER_TEMP}/iltero-tools/venv/bin/python"
  cat > "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero" << 'EOF'
#!/bin/bash
echo "iltero $*" >> "${STUB_LOG}"
exit "${CLI_EXIT}"
EOF
  chmod +x "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero"
}

# --- check -------------------------------------------------------------------

@test "check refuses pull_request_target and workflow_run events" {
  GITHUB_EVENT_NAME=pull_request_target run "${RUN}" check
  [ "${status}" -eq 1 ]
  GITHUB_EVENT_NAME=workflow_run run "${RUN}" check
  [ "${status}" -eq 1 ]
}

@test "check refuses pull request events" {
  GITHUB_EVENT_NAME=pull_request run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Use the preview action instead"* ]]
}

@test "check requires the job to grant id-token: write" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL
  run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"id-token: write"* ]]
}

@test "check requires the CLI that setup installs" {
  rm "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero"
  run "${RUN}" check
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Run the setup action first"* ]]
}

@test "check accepts push, workflow_dispatch and schedule events" {
  local event
  for event in push workflow_dispatch schedule; do
    GITHUB_EVENT_NAME="${event}" run "${RUN}" check
    [ "${status}" -eq 0 ]
  done
}

# --- close -------------------------------------------------------------------

@test "close closes the pipeline run's run for the environment" {
  run "${RUN}" close production
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --environment=production" "${STUB_LOG}"
}

@test "close passes a value starting with a dash as a value, not an option" {
  run "${RUN}" close "--help"
  grep -qx "iltero run close --environment=--help" "${STUB_LOG}"
}

@test "close fails with the CLI's exit code" {
  CLI_EXIT=9 run "${RUN}" close production
  [ "${status}" -eq 9 ]
}

@test "close requires exactly the environment" {
  run "${RUN}" close
  [ "${status}" -eq 1 ]
  run "${RUN}" close production extra
  [ "${status}" -eq 1 ]
}

@test "the close action closes the run from the stack's working directory" {
  run awk '/- name: Close the run/ { inside = 1; next } inside && /working-directory:/ { sub(/^ +/, ""); print; exit }' \
    "${REPO_ROOT}/close/action.yml"
  [ "${output}" = 'working-directory: ${{ inputs.working-directory }}' ]
}
