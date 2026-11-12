#!/bin/bash
#
# Whether the project is linked to the server. Source this file after
# common.sh. A project is linked when its .iltero/config.yml has a platform
# section; the CLI decides, with its own config search and checks.

# Prints "true" when the project in the current directory is linked, and
# "false" when it is not. Stops when the CLI finds no valid config.
project_linked() {
  local cli tools shown
  cli="$(cli_path)"
  tools="$(tools_dir)"
  shown="$("${cli}" config show --format=json)" || die "The CLI found no valid .iltero/config.yml."
  "${tools}/venv/bin/python" -I -c '
import json, sys
linked = json.loads(sys.stdin.read()).get("linked")
if not isinstance(linked, bool):
    sys.exit("the config report has no linked field")
print("true" if linked else "false")
' <<< "${shown}" || die "The CLI's config report could not be read."
}

# Sets SERVER_ARGS to the CLI options that send a stage's record to the
# server when LINKED is true and, when STORE_RECORDS is true, keep the record
# and its files in the run's artifact store. A pull request's local check uses
# neither. The CLI refuses --store in a project that is not linked. Stops when
# STORE_RECORDS is not true or false.
set_server_args() {
  local linked="$1"
  require_true_or_false store-records "${STORE_RECORDS:-}"
  SERVER_ARGS=()
  ! is_pull_request_event || return 0
  [[ "${linked}" == false ]] || SERVER_ARGS+=(--upload)
  [[ "${STORE_RECORDS}" == false ]] || SERVER_ARGS+=(--store)
}
