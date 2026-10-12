#!/bin/bash
#
# The stack's units, as the CLI lists them. Source this file after common.sh.

# Prints each unit as "name<TAB>directory", in deploy order, from the CLI.
list_units() {
  local cli tools listing
  cli="$(cli_path)"
  tools="$(tools_dir)"
  listing="$("${cli}" units list --format=json)" || die "The CLI could not list the units."
  "${tools}/venv/bin/python" -c '
import json, sys
units = json.loads(sys.stdin.read())
if not isinstance(units, list):
    sys.exit("the unit list is not a list")
for unit in units:
    name, directory = unit.get("name"), unit.get("working_directory")
    if not isinstance(name, str) or not isinstance(directory, str):
        sys.exit("a unit has no name or working directory")
    print(f"{name}\t{directory}")
' <<< "${listing}" || die "The CLI's unit list could not be read."
}

# Stops unless a unit's name and directory are safe to use.
check_unit() {
  local name="$1"
  local dir="$2"
  [[ "${name}" =~ ${UNIT_NAME_PATTERN} ]] || die "Unit name '${name}' does not follow the unit-name rule."
  [[ "${dir}" != /* && "/${dir}/" != */../* ]] || die "Unit '${name}' has a directory outside the stack: '${dir}'."
  [[ -d "${dir}" ]] || die "Unit '${name}' has no directory '${dir}'."
}

# Lists and checks every unit into FILE, before anything runs, so a bad unit
# stops the step before the first one.
list_checked_units() {
  local file="$1"
  local name dir
  list_units > "${file}" || exit 1
  while IFS=$'\t' read -r name dir; do
    check_unit "${name}" "${dir}"
  done < "${file}"
}
