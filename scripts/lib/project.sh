#!/bin/bash
#
# Whether the project is linked to the server. Source this file after
# common.sh. A project is linked when its .iltero/config.yml has a platform
# section; the CLI decides, with its own config search and checks.

# Prints "true" when the project in the current directory is linked, and
# "false" when it is not. Stops with the CLI's exit code when the CLI cannot
# read the config.
project_linked() {
  local cli tools shown status=0
  # Callers run this function inside $(...), where errexit is off, so each
  # failure stops it here.
  cli="$(cli_path)" || exit 1
  tools="$(tools_dir)" || exit 1
  shown="$("${cli}" config show --format=json)" || status=$?
  [[ "${status}" -eq 0 ]] \
    || exit_with_error "${status}" "The CLI could not read the project's .iltero/config.yml. Its message above says why."
  "${tools}/venv/bin/python" -I -c '
import json, sys
linked = json.loads(sys.stdin.read()).get("linked")
if not isinstance(linked, bool):
    sys.exit("the config report has no linked field")
print("true" if linked else "false")
' <<< "${shown}" || die "The CLI's config report could not be read."
}

# Sets SERVER_OPTIONS to the CLI options that send a stage's record to the
# server when LINKED is true and, when STORE_RECORDS is true, keep the record
# and its files in the run's artifact store. A pull request's local check uses
# neither. The CLI refuses --store in a project that is not linked. Stops when
# STORE_RECORDS is not true or false.
set_server_options() {
  local linked="$1"
  require_true_or_false store-records "${STORE_RECORDS:-}"
  SERVER_OPTIONS=()
  ! is_pull_request_event || return 0
  [[ "${linked}" == false ]] || SERVER_OPTIONS+=(--upload)
  [[ "${STORE_RECORDS}" == false ]] || SERVER_OPTIONS+=(--store)
}
