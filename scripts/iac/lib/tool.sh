#!/bin/bash
#
# Loads the adapter of the infrastructure-as-code (IaC) tool a stack uses,
# from tools/<tool>/tool.sh. Every adapter defines the interface below, so
# deploy and preview never name a tool. An adapter keeps its private names
# under its own prefix (for example terraform_ and TERRAFORM_). It sets its
# constants with readonly and its other globals with plain assignments, never
# with declare or local at its top level: load_tool sources it from inside a
# function. Source this file after common.sh.

# The tools the actions can run, each with an adapter in tools/.
readonly SUPPORTED_TOOLS=(terraform)

# The functions every adapter defines.
#   tool_install VERSION          Install VERSION; set TOOL_INSTALLED_PATH.
#   tool_input_variable_names     Print the names of the job's variables the
#                                 tool reads as its own input variables.
#   tool_state_check_environment WORK
#                                 Print the NAME=VALUE pairs, one per line,
#                                 the CLI's state check needs.
#   tool_registry_token_variable HOST
#                                 Print the variable that carries a token for
#                                 the private module registry HOST.
#   tool_check_environment_settings DIR ENVIRONMENT
#                                 Return non-zero, with the reason on stderr,
#                                 when the unit in DIR is not set up for
#                                 ENVIRONMENT.
#   tool_deploy_init WORK DIR ENVIRONMENT [TOKEN_PAIR]
#   tool_deploy_plan WORK DIR ENVIRONMENT
#   tool_apply WORK DIR
#   tool_read_state WORK DIR
#   tool_take_reading WORK DIR FILE
#   tool_preview_plan WORK DIR ENVIRONMENT [TOKEN_PAIR]
#                                 Set PLANNED_WITHOUT_UPSTREAM to true or false.
readonly TOOL_INTERFACE_FUNCTIONS=(
  tool_install tool_input_variable_names tool_state_check_environment tool_registry_token_variable
  tool_check_environment_settings tool_deploy_init tool_deploy_plan tool_apply tool_read_state tool_take_reading tool_preview_plan
)
# The constants every adapter defines.
#   TOOL_DISPLAY_NAME      The tool's name as a person writes it.
#   TOOL_DEFAULT_VERSION   The version installed when tool-version is empty.
#   TOOL_DATA_FOLDER_NAME  The folder in a unit's work folder for the tool's data.
#   TOOL_SAVED_PLAN_FILE   The saved plan, in a unit's work folder.
#   TOOL_APPLY_LOG_FILE    The log of the apply, in a unit's work folder.
#   TOOL_HOME_FOLDERS      The folders under the home folder the tool reads.
readonly TOOL_INTERFACE_CONSTANTS=(
  TOOL_DISPLAY_NAME TOOL_DEFAULT_VERSION TOOL_DATA_FOLDER_NAME TOOL_SAVED_PLAN_FILE TOOL_APPLY_LOG_FILE
  TOOL_HOME_FOLDERS
)

# The job's variables passed to every call of the tool, as NAME=VALUE pairs:
# deploy sets the cloud's credentials and the tool's input variables, and
# preview sets only mock credentials. Each script sets it once, then makes it
# read-only. The adapter reads it.
# shellcheck disable=SC2034
TOOL_ENVIRONMENT_PAIRS=()

# Stops unless TOOL is a supported tool, then loads its adapter and checks
# that it defines the whole interface.
load_tool() {
  local tool="$1" known adapter name
  for known in "${SUPPORTED_TOOLS[@]}"; do
    [[ "${tool}" == "${known}" ]] || continue
    adapter="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../tools/${tool}" > /dev/null && pwd)" \
      || die "The adapter of the tool '${tool}' is missing."
    # shellcheck source=/dev/null
    source "${adapter}/tool.sh"
    for name in "${TOOL_INTERFACE_FUNCTIONS[@]}"; do
      declare -F "${name}" > /dev/null || die "The adapter of the tool '${tool}' does not define ${name}."
    done
    for name in "${TOOL_INTERFACE_CONSTANTS[@]}"; do
      declare -p "${name}" > /dev/null 2>&1 || die "The adapter of the tool '${tool}' does not define ${name}."
    done
    return 0
  done
  die "The tool input must be one of: ${SUPPORTED_TOOLS[*]}. It is '${tool}'."
}
