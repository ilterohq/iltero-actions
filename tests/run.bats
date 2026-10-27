#!/usr/bin/env bats
#
# Tests for scripts/run.sh, the body of the `open` and `close` actions.

load test_helper

readonly RUN_ID="7d8e9f00-1a2b-4c3d-8e4f-5a6b7c8d9e0f"

setup() {
  make_runner
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example"
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token"
  export CLI_EXIT=0
  export LINKED=true
  RUN="${REPO_ROOT}/scripts/run.sh"
  # A stand-in for the CLI that setup installs. It records its arguments and,
  # like the real `run open`, writes the run's outputs.
  mkdir -p "${RUNNER_TEMP}/iltero-tools/venv/bin"
  ln -s "$(command -v python3)" "${RUNNER_TEMP}/iltero-tools/venv/bin/python"
  cat > "${RUNNER_TEMP}/iltero-tools/venv/bin/iltero" << 'EOF'
#!/bin/bash
if [[ "$1 $2" == "config show" ]]; then
  echo "{\"linked\": ${LINKED}}"
  exit 0
fi
echo "iltero $*" >> "${STUB_LOG}"
if [[ "$1 $2" == "run open" && "${CLI_EXIT}" -eq 0 ]]; then
  echo "run_id=7d8e9f00-1a2b-4c3d-8e4f-5a6b7c8d9e0f" >> "${GITHUB_OUTPUT}"
  echo "run_settings_digest=sha256:abc" >> "${GITHUB_OUTPUT}"
fi
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

# --- open --------------------------------------------------------------------

@test "open opens the run from its plan stage, for the stack the config names" {
  run "${RUN}" open production
  [ "${status}" -eq 0 ]
  grep -qx "iltero run open --stage=plan --environment=production" "${STUB_LOG}"
}

@test "open refuses a project without a platform section" {
  LINKED=false run "${RUN}" open production
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no platform section"* ]]
  ! grep -q "run open" "${STUB_LOG}" || false
}

@test "open leaves the run's outputs the CLI wrote" {
  run "${RUN}" open production
  [ "${status}" -eq 0 ]
  [ "$(output_value run_id)" = "${RUN_ID}" ]
  [ "$(output_value run_settings_digest)" = "sha256:abc" ]
}

@test "open passes a value starting with a dash as a value, not an option" {
  run "${RUN}" open "--help"
  grep -qx "iltero run open --stage=plan --environment=--help" "${STUB_LOG}"
}

@test "open fails with the CLI's exit code" {
  CLI_EXIT=8 run "${RUN}" open production
  [ "${status}" -eq 8 ]
}

@test "open requires exactly the environment" {
  run "${RUN}" open
  [ "${status}" -eq 1 ]
  run "${RUN}" open production extra
  [ "${status}" -eq 1 ]
}

# --- close -------------------------------------------------------------------

@test "close closes the run" {
  run "${RUN}" close "${RUN_ID}"
  [ "${status}" -eq 0 ]
  grep -qx "iltero run close --run-id=${RUN_ID}" "${STUB_LOG}"
}

@test "close fails with the CLI's exit code" {
  CLI_EXIT=2 run "${RUN}" close "${RUN_ID}"
  [ "${status}" -eq 2 ]
}

@test "close requires the run id" {
  run "${RUN}" close
  [ "${status}" -eq 1 ]
}
