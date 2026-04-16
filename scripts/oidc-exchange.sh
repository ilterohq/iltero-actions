#!/bin/bash
# =============================================================================
# Iltero OIDC Exchange
# =============================================================================
# Shared between ilterohq/iltero-actions (root) and
# ilterohq/iltero-actions/setup-oidc. Invokes `iltero auth oidc` with
# `--format github-actions` so the CLI writes ILTERO_TOKEN /
# ILTERO_REGISTRY_TOKEN / expires_at into $GITHUB_ENV and $GITHUB_OUTPUT.
#
# Inputs (env vars):
#   ILTERO_STACK_ID    required — UUID of the stack
#   ILTERO_ORG_ID      required — UUID of the org
#   ILTERO_API_URL     required — set by the upstream setup step
#   INPUT_API_URL      optional — explicit override from composite input
#
# Audience convention: derived from the API URL host (scheme + port + path
# stripped). The backend applies the same derivation against its configured
# host, so `OIDC_EXPECTED_AUDIENCE` stays in lockstep with the URL the client
# calls — no separate audience setting to keep in sync.
# =============================================================================

set -euo pipefail

if [[ -z "${ILTERO_STACK_ID:-}" ]]; then
  echo "::error::ILTERO_STACK_ID is required for OIDC exchange"
  exit 1
fi
if [[ -z "${ILTERO_ORG_ID:-}" ]]; then
  echo "::error::ILTERO_ORG_ID is required for OIDC exchange"
  exit 1
fi

# Preflight: fail loud if the caller forgot `permissions: id-token: write`.
# Without it, the CLI's JWT request to GitHub returns an opaque error.
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "::error::OIDC token request URL not available."
  echo "::error::Add 'permissions: { id-token: write }' to the workflow or job."
  exit 1
fi

RESOLVED_API_URL="${INPUT_API_URL:-${ILTERO_API_URL:-}}"
if [[ -z "${RESOLVED_API_URL}" ]]; then
  echo "::error::ILTERO_API_URL is not set. The upstream setup step should set it."
  exit 1
fi

# Derive the OIDC audience from the API URL host.
# https://api.iltero.io/v1  ->  api.iltero.io
# http://api.iltero.local:8000  ->  api.iltero.local
AUDIENCE="${RESOLVED_API_URL#*://}"
AUDIENCE="${AUDIENCE%%/*}"
AUDIENCE="${AUDIENCE%%:*}"
if [[ -z "${AUDIENCE}" ]]; then
  echo "::error::Could not derive OIDC audience from ILTERO_API_URL=${RESOLVED_API_URL}"
  exit 1
fi

iltero auth oidc \
  --stack-id "${ILTERO_STACK_ID}" \
  --org-id "${ILTERO_ORG_ID}" \
  --api-url "${RESOLVED_API_URL}" \
  --audience "${AUDIENCE}" \
  --format github-actions
