#!/bin/bash
#
# Runs the IaC tool under guard: in its own session, with a scrubbed
# environment, with every process it leaves running stopped when it exits,
# and with the step stopped when the files the action trusts changed while
# it ran. Holds nothing that is specific to one tool. Source this file after
# common.sh.

# The absolute path of the helper that starts the tool, found when this file
# is sourced: the callers change directory before they run the tool.
RUN_GUARDED_HELPER="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" > /dev/null && pwd)/run_guarded.py"
readonly RUN_GUARDED_HELPER
# The action's own folder: its action files and the scripts that run between
# the tool's calls.
ACTION_DIRECTORY="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../../.." > /dev/null && pwd)"
readonly ACTION_DIRECTORY

# The variables of the job that run_guarded always gives the tool.
readonly GUARDED_BASE_ENV=(PATH HOME)
# The job's network settings, which run_guarded gives the tool when the job
# sets them: the proxy to reach the internet through, the hosts to reach
# without it, and the certificates to trust. A runner behind a proxy needs
# them to download the tool's providers and modules.
readonly GUARDED_NETWORK_ENV=(
  HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy
  SSL_CERT_FILE SSL_CERT_DIR
)

# Succeeds when run_guarded takes NAME from the job's own environment, so
# no caller and no adapter may set it.
guard_takes_from_job() {
  [[ " ${GUARDED_BASE_ENV[*]} ${GUARDED_NETWORK_ENV[*]} " == *" $1 "* ]]
}

# The step's own error output, kept when this file is sourced, so stop_step's
# message reaches the job log even when the caller redirected stderr.
# The tool does not get it.
exec {STEP_ERROR_OUTPUT}>&2

# The step's own files and folders that the fingerprint also covers. Added
# with trust_paths.
TRUSTED_STEP_PATHS=()

# Adds each PATH, a file or folder the step writes and reads again between
# the tool's calls, such as its unit list, its summary and its records
# directory, to what the fingerprint covers.
trust_paths() {
  TRUSTED_STEP_PATHS+=("$@")
}

# Prints the folder of the Python installation that the tools' virtual
# environment runs, from the home line of its pyvenv.cfg.
python_install_dir() {
  local key value
  while IFS=' =' read -r key value; do
    if [[ "${key}" == home ]]; then
      echo "${value%/*}"
      return 0
    fi
  done < "$(tools_dir)/venv/pyvenv.cfg"
  return 1
}

# Prints one fingerprint of the files the action trusts while the tool runs:
# the tools that `setup` installed, the Python installation they run on when
# the job's user can write it, the action's own folder, the tool's folders in
# the home folder (TOOL_HOME_FOLDERS), the step's own files and records
# directory, the files through which the step sets outputs, environment and
# the job summary, the commands in each folder on PATH, and every link in the
# runner's temporary folder outside the units' tool data folders
# (TOOL_DATA_FOLDER_NAME). It lists each entry's type, mode, inode, change
# time, size, path and link target. The job's user can change no file without
# changing its change time. It calls system tools by absolute path only.
trusted_files_fingerprint() {
  local tools python_install roots search_path directory file commands=()
  tools="$(tools_dir)" || return 1
  python_install="$(python_install_dir)" || return 1
  roots=("${tools}" "${ACTION_DIRECTORY}")
  [[ ! -w "${python_install}" ]] || roots+=("${python_install}")
  roots+=(${TRUSTED_STEP_PATHS[@]+"${TRUSTED_STEP_PATHS[@]}"})
  for file in "${GITHUB_OUTPUT:-}" "${GITHUB_ENV:-}" "${GITHUB_PATH:-}" "${GITHUB_STEP_SUMMARY:-}" "${GITHUB_STATE:-}"; do
    [[ -z "${file}" || ! -e "${file}" ]] || roots+=("${file}")
  done
  IFS=: read -r -a search_path <<< "${PATH}"
  {
    for directory in "${TOOL_HOME_FOLDERS[@]/#/${HOME}/}"; do
      if [[ -e "${directory}" ]]; then
        roots+=("${directory}")
      else
        printf 'absent %s\n' "${directory}"
      fi
    done
    for directory in "${search_path[@]}"; do
      if [[ -d "${directory}" ]]; then
        commands+=("${directory}")
      else
        printf 'absent %s\n' "${directory}"
      fi
    done
    /usr/bin/find -H "${roots[@]}" -printf '%y %m %i %C@ %s %p %l\n' | LC_ALL=C /usr/bin/sort || return 1
    if [[ ${#commands[@]} -gt 0 ]]; then
      /usr/bin/find -H "${commands[@]}" -maxdepth 1 -printf '%y %m %i %C@ %s %p %l\n' | LC_ALL=C /usr/bin/sort \
        || return 1
    fi
    /usr/bin/find "${RUNNER_TEMP}" -type d -path "*/units/*/${TOOL_DATA_FOLDER_NAME}" -prune -o -type l -printf '%p %l\n' | LC_ALL=C /usr/bin/sort \
      || return 1
  } | /usr/bin/sha256sum
}

# Prints MESSAGE as an error and ends the whole step, also when called from a
# subshell. Turns workflow commands back on first, so the error shows.
stop_step() {
  [[ -z "${COMMANDS_TOKEN:-}" ]] || echo "::${COMMANDS_TOKEN}::" >&"${STEP_ERROR_OUTPUT}"
  printf '::error::%s\n' "$1" >&"${STEP_ERROR_OUTPUT}"
  kill -s TERM "$$"
  exit 1
}

# Runs COMMAND with ARGS for the unit whose work folder is WORK. Its
# environment holds only PATH, HOME, the job's network settings
# (GUARDED_NETWORK_ENV) and the NAME=VALUE pairs given before "--", and
# nothing else from the job's environment. The pairs are exported
# in a subshell, and run_guarded.py starts the command with only those names,
# so no value is passed on a command line. When the command exits,
# run_guarded.py stops every process it left running. The step then stops
# unless the files the action trusts are as they were before the command ran.
# Returns the command's exit code. PREPARE, when not empty, is a function the
# guard calls with WORK after its first fingerprint, and whose output lines
# are more NAME=VALUE pairs: the adapter makes per-call files there.
run_guarded() {
  local work="$1"
  local prepare="$2"
  shift 2
  local pairs=() names=("${GUARDED_BASE_ENV[@]}" "${GUARDED_NETWORK_ENV[@]}") pair
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "run_guarded takes NAME=VALUE pairs before --."
    ! guard_takes_from_job "${1%%=*}" || die "run_guarded takes ${1%%=*} from the job's environment, so a NAME=VALUE pair cannot set it."
    pairs+=("$1")
    shift
  done
  [[ $# -gt 1 ]] || die "run_guarded needs -- and a command."
  shift
  [[ -n "${HOME:-}" ]] || die "HOME is not set."
  local before after status=0 prepared=() prepared_lines=""
  before="$(trusted_files_fingerprint)" || stop_step "The action could not fingerprint its tools before ${TOOL_DISPLAY_NAME} ran."
  mkdir -p "${work}"
  if [[ -n "${prepare}" ]]; then
    prepared_lines="$("${prepare}" "${work}")" \
      || stop_step "The action could not prepare the files ${TOOL_DISPLAY_NAME} reads."
    while IFS= read -r pair; do
      [[ -n "${pair}" ]] || continue
      # Each line is one NAME=VALUE pair, and never sets a variable the guard
      # takes from the job.
      if [[ ! "${pair}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || guard_takes_from_job "${pair%%=*}"; then
        stop_step "The ${TOOL_DISPLAY_NAME} adapter prepared a variable the guard does not accept."
      fi
      prepared+=("${pair}")
    done <<< "${prepared_lines}"
  fi
  for pair in ${pairs[@]+"${pairs[@]}"} ${prepared[@]+"${prepared[@]}"}; do
    names+=("${pair%%=*}")
  done
  (
    exec {STEP_ERROR_OUTPUT}>&-
    for pair in ${pairs[@]+"${pairs[@]}"} ${prepared[@]+"${prepared[@]}"}; do
      export "${pair?}"
    done
    # -B: the helper writes no compiled files into the Python installation.
    exec "$(tools_dir)/venv/bin/python" -I -B "${RUN_GUARDED_HELPER}" "${#names[@]}" "${names[@]}" "$@"
  ) || status=$?
  after="$(trusted_files_fingerprint)" || stop_step "The action could not fingerprint its tools after ${TOOL_DISPLAY_NAME} ran."
  [[ "${after}" == "${before}" ]] \
    || stop_step "The action's tools or scripts changed while ${TOOL_DISPLAY_NAME} ran, so the step stops. Run the job again on a fresh runner."
  return "${status}"
}
