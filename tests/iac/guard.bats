#!/usr/bin/env bats
#
# Tests for scripts/iac/lib/guard.sh, which runs the infrastructure-as-code (IaC)
# tool under guard. The tool here is a stand-in, run through the Terraform adapter.

load ../test_helper
# The test of a tool that cannot start expects its code with run -127.
bats_require_minimum_version 1.5.0

setup() {
  make_runner
  TOOLS="${RUNNER_TEMP}/iltero-tools"
  mkdir -p "${TOOLS}/bin" "${TOOLS}/venv/bin"
  ln -s "$(command -v python3)" "${TOOLS}/venv/bin/python"
  # The Python installation the virtual environment runs on.
  mkdir -p "${BATS_TEST_TMPDIR}/python/bin"
  echo "home = ${BATS_TEST_TMPDIR}/python/bin" > "${TOOLS}/venv/pyvenv.cfg"
  # A stand-in for Terraform. It prints exactly the environment it was given,
  # read from /proc as Python may add to its own, then its arguments, and
  # exits with TERRAFORM_EXIT when that is set.
  cat > "${TOOLS}/bin/terraform" << STUB
#!$(command -v python3)
import sys
with open("/proc/self/environ", "rb") as given:
    entries = sorted(entry.decode() for entry in given.read().split(b"\\0") if entry)
print("\\n".join(entries))
print("args " + " ".join(sys.argv[1:]))
code = [entry.split("=", 1)[1] for entry in entries if entry.startswith("TERRAFORM_EXIT=")]
sys.exit(int(code[0]) if code else 0)
STUB
  chmod +x "${TOOLS}/bin/terraform"
  # A stand-in for env that records any call with arguments.
  # The stub's variables expand when it runs, not here.
  # shellcheck disable=SC2016
  stub env 'if [[ $# -gt 0 ]]; then echo "env $*" >> "${STUB_LOG}"; fi; exec /usr/bin/env "$@"'
  export JOB_SECRET="job-secret"
  source "${REPO_ROOT}/scripts/lib/common.sh"
  source "${REPO_ROOT}/scripts/iac/lib/guard.sh"
  source "${REPO_ROOT}/scripts/iac/lib/tool.sh"
  load_tool terraform
}

# Runs terraform_run in its own bash, as a step's script does, with workflow
# commands paused and both output streams sent to files, as deploy does for
# plan.json. Prints only what reaches the step's own error output.
run_tool_like_a_step() {
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform
    trap 'exit 143' TERM
    pause_commands > /dev/null
    echo \"\${COMMANDS_TOKEN}\" > '${BATS_TEST_TMPDIR}/token'
    (terraform_run '${BATS_TEST_TMPDIR}/work' -- plan) > '${BATS_TEST_TMPDIR}/stdout' 2> '${BATS_TEST_TMPDIR}/stderr'
    echo carried on"
}

@test "the tool gets no exported function and no variable bash cannot name" {
  hidden() { :; }
  export -f hidden
  run /usr/bin/env "a-b=hyphen" "x.y=dot" "BASH_FUNC_bad%%=x" bash -c \
    "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- version"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"args version"* ]]
  [[ "${output}" != *"BASH_FUNC_"* ]]
  [[ "${output}" != *"hyphen"* ]]
  [[ "${output}" != *"x.y="* ]]
}

@test "no value given to the tool is passed on a command line" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" "TF_TOKEN_x=secret" -- plan
  [ "${status}" -eq 0 ]
  [[ "$(grep '^args ' <<< "${output}")" != *"secret"* ]]
  run grep -q "secret" "${STUB_LOG}"
  [ "${status}" -eq 1 ]
}

@test "the tool's exit code passes through" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" "TERRAFORM_EXIT=3" -- plan
  [ "${status}" -eq 3 ]
}

@test "only NAME=VALUE pairs may come before --" {
  run terraform_run "${BATS_TEST_TMPDIR}/work" JOB_SECRET -- plan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"run_guarded takes NAME=VALUE pairs before --."* ]]
  [[ "${output}" != *"job-secret"* ]]
}

@test "a process the tool leaves running is stopped when the tool exits" {
  cat > "${TOOLS}/bin/terraform" << STUB
#!/bin/bash
# Leaves one process in its own session and one that starts a new session.
sleep 300 &
echo "\$!" > "${BATS_TEST_TMPDIR}/same-session.pid"
setsid bash -c 'echo "\$\$" > "${BATS_TEST_TMPDIR}/new-session.pid"; exec sleep 300' &
sleep 1
exit 4
STUB
  chmod +x "${TOOLS}/bin/terraform"
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- apply
  [ "${status}" -eq 4 ]
  local pid
  for pid in "$(cat "${BATS_TEST_TMPDIR}/same-session.pid")" "$(cat "${BATS_TEST_TMPDIR}/new-session.pid")"; do
    ! kill -0 "${pid}" 2> /dev/null || false
  done
}

@test "a tool stopped by a signal fails with the shell's code for that signal" {
  printf '#!/bin/bash\nkill -TERM $$\n' > "${TOOLS}/bin/terraform"
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 143 ]
}

@test "the tool gets the system's default handling of the signals Python ignores" {
  printf '#!/bin/bash\ngrep "^SigIgn:" /proc/self/status\n' > "${TOOLS}/bin/terraform"
  run terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 0 ]
  local ignored=$((16#${output##*[[:space:]]}))
  # SIGPIPE is signal 13 and SIGXFSZ is signal 25; bit N-1 marks signal N.
  [ $((ignored & (1 << 12))) -eq 0 ]
  [ $((ignored & (1 << 24))) -eq 0 ]
}

@test "a tool that cannot start fails with the shell's code and says why" {
  printf '#!/no/such/interpreter\n' > "${TOOLS}/bin/terraform"
  run -127 terraform_run "${BATS_TEST_TMPDIR}/work" -- plan
  [ "${status}" -eq 127 ]
  [[ "${output}" == *"::error::The infrastructure-as-code (IaC) tool could not start: No such file or directory."* ]]
}

@test "a stop signal sent to the helper reaches the tool" {
  cat > "${TOOLS}/bin/terraform" << STUB
#!/bin/bash
trap 'echo stopped > "${BATS_TEST_TMPDIR}/stopped"; exit 3' TERM
touch "${BATS_TEST_TMPDIR}/started"
while true; do sleep 0.1; done
STUB
  chmod +x "${TOOLS}/bin/terraform"
  terraform_run "${BATS_TEST_TMPDIR}/work" -- apply &
  local helper=$!
  local tries=0
  until [[ -e "${BATS_TEST_TMPDIR}/started" ]] || [[ "${tries}" -ge 100 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  pkill -TERM -f "run_guarded.py .*${TOOLS}/bin/terraform"
  local status=0
  wait "${helper}" || status=$?
  [ "${status}" -eq 3 ]
  [ -e "${BATS_TEST_TMPDIR}/stopped" ]
}

@test "the step stops when one of the action's tools changes while the IaC tool runs" {
  printf '#!/bin/bash\necho changed >> "%s"\n' "${TOOLS}/bin/terraform" > "${BATS_TEST_TMPDIR}/rewrite"
  cp "${BATS_TEST_TMPDIR}/rewrite" "${TOOLS}/bin/terraform"
  chmod +x "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; (terraform_run '${BATS_TEST_TMPDIR}/work' -- plan) || true; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"::error::The action's tools or scripts changed while Terraform ran, so the step stops."* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step stops when the tool changes a scanner the CLI installed" {
  local package="${TOOLS}/scanners/checkov/0123456789abcdef/packages/checkov"
  mkdir -p "${package}"
  echo 'original' > "${package}/main.py"
  printf '#!/bin/bash\necho changed >> "%s"\n' "${package}/main.py" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; (terraform_run '${BATS_TEST_TMPDIR}/work' -- plan) || true; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"::error::The action's tools or scripts changed while Terraform ran, so the step stops."* ]]
  [[ "${output}" != *"carried on"* ]]
  # The CLI keeps its scanners in that folder.
  [ "$(scanner_dir)" = "${TOOLS}/scanners" ]
}

@test "the step stops when the tool adds a command to a folder on PATH" {
  printf '#!/bin/bash\ntouch "%s/grep"\n' "${STUBS}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step stops when the tool creates a folder that is on PATH" {
  local missing="${BATS_TEST_TMPDIR}/not-yet"
  printf '#!/bin/bash\nmkdir "%s"\n' "${missing}" > "${TOOLS}/bin/terraform"
  run bash -c "PATH='${missing}':\"\${PATH}\"; source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "the stop message reaches the log, with workflow commands back on, when the caller redirected the output" {
  printf '#!/bin/bash\necho changed >> "%s"\n' "${TOOLS}/bin/terraform" > "${BATS_TEST_TMPDIR}/rewrite"
  cp "${BATS_TEST_TMPDIR}/rewrite" "${TOOLS}/bin/terraform"
  chmod +x "${TOOLS}/bin/terraform"
  run_tool_like_a_step
  [ "${status}" -eq 143 ]
  [[ "${output}" != *"carried on"* ]]
  local token
  token="$(cat "${BATS_TEST_TMPDIR}/token")"
  [[ "${output}" == *"::${token}::"*"::error::The action's tools or scripts changed while Terraform ran"* ]]
}

@test "the step stops when the tool changes the records directory" {
  local records="${BATS_TEST_TMPDIR}/records"
  mkdir -p "${records}"
  printf '#!/bin/bash\ntouch "%s/car.json"\n' "${records}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; trust_paths '${records}'; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step stops when the tool changes the step's output file" {
  printf '#!/bin/bash\necho "x=y" >> "%s"\n' "${GITHUB_OUTPUT}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step stops when the tool leaves a link in the runner's temporary folder" {
  printf '#!/bin/bash\nmkdir -p "%s/elsewhere"; ln -s "%s/bin/opa" "%s/elsewhere/terraform-cli-config.tfrc"\n' \
    "${RUNNER_TEMP}" "${TOOLS}" "${RUNNER_TEMP}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step fails when processes the tool left running cannot be stopped in time" {
  run "${TOOLS}/venv/bin/python" -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("helper", sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
helper.STOP_DEADLINE_SECONDS = 0
sys.argv = ["run_guarded.py", "0", "/bin/true"]
helper.main()
' "${REPO_ROOT}/scripts/iac/lib/run_guarded.py"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"::error::Some processes the infrastructure-as-code (IaC) tool left running could not be stopped within 0 seconds."* ]]
}

@test "the step stops when the tool changes the Python installation the tools run on" {
  printf '#!/bin/bash\ntouch "%s/python/lib-changed"\n' "${BATS_TEST_TMPDIR}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; source '${REPO_ROOT}/scripts/iac/lib/guard.sh'; source '${REPO_ROOT}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}

@test "the step stops when the tool changes the action's own files" {
  local action="${BATS_TEST_TMPDIR}/action"
  mkdir -p "${action}"
  cp -R "${REPO_ROOT}/scripts" "${action}/scripts"
  printf '#!/bin/bash\necho "# changed" >> "%s/scripts/iac/deploy.sh"\n' "${action}" > "${TOOLS}/bin/terraform"
  run bash -c "source '${action}/scripts/lib/common.sh'; source '${action}/scripts/iac/lib/guard.sh'; source '${action}/scripts/iac/lib/tool.sh'; load_tool terraform; terraform_run '${BATS_TEST_TMPDIR}/work' -- plan; echo carried on"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"changed while Terraform ran"* ]]
  [[ "${output}" != *"carried on"* ]]
}
