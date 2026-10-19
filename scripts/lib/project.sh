#!/bin/bash
#
# Whether the project is linked to Iltero Platform. Source this file after
# common.sh. A project is linked when its .iltero/config.yml has a platform
# section; the CLI decides, with its own config search and checks.

# Stops unless LINKED is true: only a linked project can use the Iltero
# module registry.
require_linked_for_registry() {
  local linked="$1"
  [[ "${linked}" == true ]] \
    || die "This project has no platform section in .iltero/config.yml, so it cannot use the Iltero module registry."
}

# Prints "true" when the project in the current directory is linked, and
# "false" when it is not. Stops when the CLI finds no valid config.
project_linked() {
  local cli tools shown
  cli="$(cli_path)"
  tools="$(tools_dir)"
  shown="$("${cli}" config show --format=json)" || die "The CLI found no valid .iltero/config.yml."
  "${tools}/venv/bin/python" -c '
import json, sys
linked = json.loads(sys.stdin.read()).get("linked")
if not isinstance(linked, bool):
    sys.exit("the config report has no linked field")
print("true" if linked else "false")
' <<< "${shown}" || die "The CLI's config report could not be read."
}
