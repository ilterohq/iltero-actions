#!/bin/bash
#
# A short-lived token for the private module registry. The registry accepts
# the job's GitHub identity token, minted for the registry host's own origin.
# Source this file after common.sh.

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
# process that runs init. The token is masked first, and
# is never written to a file, an output or the log.
mint_registry_token() {
  local host="$1"
  # Each step exits on failure explicitly: callers may run this where bash
  # ignores set -e.
  local variable audience token
  variable="$(registry_token_variable "${host}")" || exit 1
  audience="https://${host}"
  require_id_token
  token="$(AUDIENCE="${audience}" "$(tools_dir)/venv/bin/python" -c '
import json, os, urllib.parse, urllib.request
url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote(os.environ["AUDIENCE"], safe="")
request = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
with urllib.request.urlopen(request, timeout=30) as response:
    print(json.load(response)["value"])
')" || die "Could not get an identity token for the registry."
  [[ -n "${token}" && "${token}" != *[[:space:]]* ]] || die "The identity token for the registry is malformed."
  echo "::add-mask::${token}"
  REGISTRY_TOKEN_ENV="${variable}=${token}"
}
