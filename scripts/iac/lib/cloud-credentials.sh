#!/bin/bash
#
# Each cloud's credentials, from one adapter per cloud in clouds/. Add a cloud
# by adding clouds/<cloud>.sh, which appends to the two arrays below. Source
# this file after common.sh.

# The variables each cloud's deploy credentials and settings arrive in. deploy
# passes these to the IaC tool, and nothing else from the job's environment
# but PATH, HOME, the job's network settings (GUARDED_NETWORK_ENV in
# lib/guard.sh) and the tool's own input variables.
CLOUD_CREDENTIAL_ENV=()
# The mock credentials the preview gives the IaC tool, as NAME=VALUE pairs.
PREVIEW_CREDENTIAL_ENV=()

CLOUD_ADAPTERS_DIRECTORY="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../clouds" > /dev/null && pwd)" \
  || die "The cloud adapters are missing."
readonly CLOUD_ADAPTERS_DIRECTORY
for cloud_adapter in "${CLOUD_ADAPTERS_DIRECTORY}"/*.sh; do
  [[ -f "${cloud_adapter}" ]] || die "No cloud adapter found in ${CLOUD_ADAPTERS_DIRECTORY}."
  # shellcheck source=/dev/null
  source "${cloud_adapter}"
done
unset cloud_adapter
# Read by the scripts that source this file.
# shellcheck disable=SC2034
readonly CLOUD_CREDENTIAL_ENV PREVIEW_CREDENTIAL_ENV
