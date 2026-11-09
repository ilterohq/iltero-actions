#!/bin/bash
#
# The private module registry: a short-lived token for it, and the check that
# the project may use it. The registry accepts the job's GitHub identity
# token, minted for the registry host's own origin. Source this file after
# common.sh.

# How long the request for the job's identity token may take.
readonly ID_TOKEN_REQUEST_TIMEOUT_SECONDS=30

# Prints the name of Terraform's credentials variable for a registry host:
# TF_TOKEN_ followed by the host, with "." written "_" and "-" written "__".
registry_token_variable() {
  local host="$1"
  [[ "${host}" =~ ^[${LOWER}0-9-]+(\.[${LOWER}0-9-]+)+$ ]] || die "Invalid registry host '${host}'."
  host="${host//-/__}"
  echo "TF_TOKEN_${host//./_}"
}

# Mints a registry token for the audience https://<host>, and sets
# REGISTRY_TOKEN_ENV to "TF_TOKEN_<host>=<token>", for the one Terraform
# process that runs init. The token is masked first, and is never written to
# a file, an output or the log. Returns non-zero, with an error annotation,
# when no token can be minted, so the caller can still write its summary.
# Callers have already checked that setup ran.
mint_registry_token() {
  local host="$1"
  # Each step returns on failure explicitly: callers may run this where bash
  # ignores set -e.
  local variable audience token
  variable="$(registry_token_variable "${host}")" || return 1
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
    || die "This project has no platform section in .iltero/config.yml, so it cannot use the Iltero module registry."
}
