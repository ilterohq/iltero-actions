#!/bin/bash
#
# The stack's units, as the CLI lists them. Source this file after common.sh.

# Prints each unit as "name<TAB>directory", in deploy order, from the CLI.
list_units() {
  local cli tools listing status=0
  # The caller runs this function with || exit, where errexit is off, so each
  # failure stops it here.
  cli="$(cli_path)" || exit 1
  tools="$(tools_dir)" || exit 1
  listing="$("${cli}" units list --format=json)" || status=$?
  [[ "${status}" -eq 0 ]] || exit_with_error "${status}" "The CLI could not list the units. Its message above says why."
  "${tools}/venv/bin/python" -I -c '
import json, sys
units = json.loads(sys.stdin.read())
if not isinstance(units, list):
    sys.exit("the unit list is not a list")
for unit in units:
    name, directory = unit.get("name"), unit.get("working_directory")
    if not isinstance(name, str) or not isinstance(directory, str):
        sys.exit("a unit has no name or working directory")
    # Each unit is one line of name, tab, directory.
    if any(not character.isprintable() for character in name + directory):
        sys.exit("a unit name or working directory holds a character that cannot be printed")
    print(f"{name}\t{directory}")
' <<< "${listing}" || die "The CLI's unit list could not be read."
}

# Stops unless a unit's name and directory are safe to use.
check_unit() {
  local name="$1"
  local dir="$2"
  check_unit_name "${name}"
  [[ "${dir}" != /* && "/${dir}/" != */../* ]] || die "Unit '${name}' has a directory outside the stack: '${dir}'."
  # Commands would read such a directory as one of their options.
  [[ "${dir}" != -* ]] || die "Unit '${name}' has a directory that starts with '-': '${dir}'. Rename the directory."
  [[ -d "${dir}" ]] || die "Unit '${name}' has no directory '${dir}'."
}

# Lists and checks every unit into FILE, before anything runs, so a bad unit
# stops the step before the first one. It also stops the step when the stack
# has no unit. It stops when two units share a name, because each unit's work
# folder is named after the unit.
list_checked_units() {
  local file="$1"
  local name dir seen=" "
  list_units > "${file}" || exit 1
  [[ -s "${file}" ]] || die "The CLI lists no units in this stack, so there is nothing to check."
  while IFS=$'\t' read -r name dir; do
    check_unit "${name}" "${dir}"
    [[ "${seen}" != *" ${name} "* ]] || die "Two units are named '${name}'. Give each unit its own name."
    seen+="${name} "
  done < "${file}"
}

# Prints the directory of the unit named NAME, from the checked unit list in
# FILE. Stops when no unit has it.
unit_dir() {
  local name="$1"
  local file="$2"
  local listed dir
  while IFS=$'\t' read -r listed dir; do
    if [[ "${listed}" == "${name}" ]]; then
      echo "${dir}"
      return 0
    fi
  done < "${file}"
  die "The stack has no unit '${name}'. Use a name that 'iltero units list' prints."
}
