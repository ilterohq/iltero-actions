#!/bin/bash
#
# The private module registry: a short-lived token for it, and the check that
# the project may use it. The registry accepts the job's GitHub identity
# token, minted for the registry host's own origin. Source this file after
# common.sh, and load the tool's adapter before calling it.

# Stops unless HOST is a registry host name, with no scheme and no path.
check_registry_host() {
  local host="$1"
  [[ "${host}" =~ ^[${LOWERCASE_LETTERS}0-9-]+(\.[${LOWERCASE_LETTERS}0-9-]+)+$ ]] \
    || die "Invalid registry host '${host}'. Use a host name such as registry.example.com, with no https:// or path."
}

# How long the request for the job's identity token may take.
readonly ID_TOKEN_REQUEST_TIMEOUT_SECONDS=30

# Mints a registry token for the audience https://<host>, and sets
# REGISTRY_TOKEN_ENV to "<variable>=<token>", where the IaC tool's adapter
# names the variable (tool_registry_token_variable), for the one call of the
# tool that downloads modules. The token is masked first, and is never written to
# a file, an output or the log. Returns non-zero, with an error annotation,
# when no token can be minted, so the caller can still write its summary.
# Callers have already checked that setup ran.
mint_registry_token() {
  local host="$1"
  # Each step returns on failure explicitly: callers may run this where bash
  # ignores set -e.
  local variable audience token
  # The check steps have already refused a host that is not a host name.
  variable="$(tool_registry_token_variable "${host}")" || return 1
  audience="https://${host}"
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" && -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || {
    echo "::error::The job cannot request its identity token. Grant it 'permissions: id-token: write'."
    return 1
  }
  token="$(AUDIENCE="${audience}" TIMEOUT_SECONDS="${ID_TOKEN_REQUEST_TIMEOUT_SECONDS}" "$(tools_dir)/venv/bin/python" -I -c '
import json, os, urllib.parse, urllib.request
url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote(os.environ["AUDIENCE"], safe="")
request = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
with urllib.request.urlopen(request, timeout=int(os.environ["TIMEOUT_SECONDS"])) as response:
    print(json.load(response)["value"])
')" || {
    echo "::error::Could not get an identity token for the registry."
    return 1
  }
  [[ -n "${token}" && "${token}" != *[[:space:]]* ]] || {
    echo "::error::The identity token for the registry is malformed."
    return 1
  }
  echo "::add-mask::${token}"
  # Read by the caller, which passes it to the init process alone.
  # shellcheck disable=SC2034
  REGISTRY_TOKEN_ENV="${variable}=${token}"
}

# Stops unless LINKED is true: only a linked project can use the Iltero
# module registry.
require_linked_for_registry() {
  local linked="$1"
  [[ "${linked}" == true ]] \
    || die "This project is not linked to the server, so it cannot use the Iltero module registry. Add a platform section to .iltero/config.yml, or leave registry-host empty."
}
