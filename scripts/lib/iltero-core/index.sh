#!/bin/bash
# =============================================================================
# Iltero Actions - Core Library Index
# =============================================================================
# Main entry point that sources all focused modules.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/iltero-core/index.sh"
#
# Modules:
#   utils.sh         - Exit codes, progress indicators, helpers
#   validation.sh    - Unit structure validation
#   scanning.sh      - Static compliance scanning
#   evaluation.sh    - Plan evaluation
#   deployment.sh    - Terraform apply + API notification
#   authorization.sh - Deploy authorization checks
#   registry.sh      - Private module registry config
#   github.sh        - GitHub Actions helpers + rich summaries
#   polling.sh       - Async scan polling with timeout
#   aggregation.sh   - Multi-unit result aggregation
#   runtime.sh       - Runtime/drift scanning
#   results.sh       - Per-stack result accumulation
# =============================================================================

set -euo pipefail

# Prevent double-sourcing
if [[ -n "${ILTERO_CORE_SOURCED:-}" ]]; then
    return 0
fi

# Get directory containing this script
ILTERO_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ILTERO_LIB_DIR="$(dirname "$ILTERO_CORE_DIR")"

# Source logging first (dependency for all modules)
if [[ -z "${ILTERO_LOGGING_SOURCED:-}" ]]; then
    source "${ILTERO_LIB_DIR}/logging.sh"
    export ILTERO_LOGGING_SOURCED=1
fi

# Source utils early (exit codes, progress indicators)
source "${ILTERO_CORE_DIR}/utils.sh"

# Source remote state tracking (needed before evaluation)
source "${ILTERO_CORE_DIR}/remote-state.sh"

# Source all modules
source "${ILTERO_CORE_DIR}/validation.sh"
source "${ILTERO_CORE_DIR}/scanning.sh"
source "${ILTERO_CORE_DIR}/evaluation.sh"
source "${ILTERO_CORE_DIR}/deployment.sh"
source "${ILTERO_CORE_DIR}/authorization.sh"
source "${ILTERO_CORE_DIR}/registry.sh"
source "${ILTERO_CORE_DIR}/github.sh"
source "${ILTERO_CORE_DIR}/polling.sh"
source "${ILTERO_CORE_DIR}/aggregation.sh"
source "${ILTERO_CORE_DIR}/runtime.sh"
source "${ILTERO_CORE_DIR}/results.sh"

# Mark as sourced
export ILTERO_CORE_SOURCED=1
