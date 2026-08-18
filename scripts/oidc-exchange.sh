#!/bin/bash
# =============================================================================
# Iltero OIDC Exchange
# =============================================================================
# Shared between ilterohq/iltero-actions (root) and
# ilterohq/iltero-actions/setup-oidc. Invokes `iltero auth oidc` with
# `--format github-actions` so the CLI writes ILTERO_TOKEN /
# ILTERO_REGISTRY_TOKEN / expires_at into $GITHUB_ENV and $GITHUB_OUTPUT.
#
# Inputs (env vars) — provide exactly one of STACK_ID or WORKSPACE_ID:
#   ILTERO_STACK_ID     stack mode — UUID of the stack (deploy-authorizing token)
#   ILTERO_WORKSPACE_ID repo mode  — UUID of the workspace (repo-scoped token)
#   ILTERO_ORG_ID       required — UUID of the org (both modes)
#   ILTERO_API_URL      required — set by the upstream setup step
#   INPUT_API_URL       optional — explicit override from composite input
#
# Audience convention: derived from the API URL host (scheme + port + path
# stripped). The backend applies the same derivation against its configured
# host, so `OIDC_EXPECTED_AUDIENCE` stays in lockstep with the URL the client
# calls — no separate audience setting to keep in sync.
# =============================================================================

set -euo pipefail

STACK_ID="${ILTERO_STACK_ID:-}"
WORKSPACE_ID="${ILTERO_WORKSPACE_ID:-}"

# Mode select: exactly one of stack-id (stack mode) or workspace-id (repo mode).
# Keyed on non-empty so an empty composite input behaves as "unset".
if [[ -n "${STACK_ID}" && -n "${WORKSPACE_ID}" ]]; then
  echo "::error::Provide exactly one of ILTERO_STACK_ID or ILTERO_WORKSPACE_ID, not both."
  exit 1
fi
if [[ -z "${STACK_ID}" && -z "${WORKSPACE_ID}" ]]; then
  echo "::error::One of ILTERO_STACK_ID (stack mode) or ILTERO_WORKSPACE_ID (repo mode) is required."
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

# Scope flag: --stack-id (stack mode) or --workspace-id (repo mode).
# --org-id is required in both modes. Validate the UUID shape before the CLI
# call (fail fast, mirrors the ci-credential resolver's validation).
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ -n "${STACK_ID}" ]]; then
  SCOPE_FLAG="--stack-id"; SCOPE_VALUE="${STACK_ID}"; SCOPE_NAME="ILTERO_STACK_ID"
else
  SCOPE_FLAG="--workspace-id"; SCOPE_VALUE="${WORKSPACE_ID}"; SCOPE_NAME="ILTERO_WORKSPACE_ID"
fi
if [[ ! "${SCOPE_VALUE}" =~ ${UUID_RE} ]]; then
  echo "::error::${SCOPE_NAME} is not a valid UUID"
  exit 1
fi
scope_args=("${SCOPE_FLAG}" "${SCOPE_VALUE}")

"${ILTERO_CLI_BIN:-iltero}" auth oidc \
  "${scope_args[@]}" \
  --org-id "${ILTERO_ORG_ID}" \
  --api-url "${RESOLVED_API_URL}" \
  --audience "${AUDIENCE}" \
  --format github-actions
