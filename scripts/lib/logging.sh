#!/bin/bash
# =============================================================================
# Iltero Actions - Logging Library
# =============================================================================
# Provides consistent logging functions for the pipeline scripts.
# Uses GitHub Actions workflow commands for proper formatting.
#
# Log levels:
#   log_info     - Informational (indented, no prefix)
#   log_success  - Pass/success result ([PASS] prefix)
#   log_warning  - Non-fatal issue ([WARN] prefix, GA annotation)
#   log_error    - Error ([FAIL] prefix, GA annotation)
#   log_debug    - Debug detail ([DEBUG] prefix, only when DEBUG=true)
#   log_step     - Compact step status (e.g., "terraform init ... ok")
#   log_result   - Final verdict line with tag (e.g., "[PASS] message")
# =============================================================================

# Colors (only used when not in GitHub Actions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "  $message"
    else
        echo -e "${BLUE}  $message${NC}"
    fi
}

log_success() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "[PASS] $message"
    else
        echo -e "${GREEN}[PASS] $message${NC}"
    fi
}

log_warning() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::warning::$message"
    else
        echo -e "${YELLOW}[WARN] $message${NC}"
    fi
}

log_error() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::error::$message"
    else
        echo -e "${RED}[FAIL] $message${NC}"
    fi
}

log_debug() {
    local message="$1"
    if [[ "${DEBUG:-}" == "true" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::debug::$message"
        else
            echo "[DEBUG] $message"
        fi
    fi
}

# Compact step status line (e.g., "  terraform init ... ok")
log_step() {
    local step="$1"
    local status="$2"
    local detail="${3:-}"
    if [[ -n "$detail" ]]; then
        echo "  ${step} ... ${status} (${detail})"
    else
        echo "  ${step} ... ${status}"
    fi
}

# Final verdict line with pass/fail tag
log_result() {
    local status="$1"  # "PASS" or "FAIL"
    local message="$2"
    if [[ "$status" == "PASS" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "[PASS] ${message}"
        else
            echo -e "${GREEN}[PASS] ${message}${NC}"
        fi
    else
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "[FAIL] ${message}"
        else
            echo -e "${RED}[FAIL] ${message}${NC}"
        fi
    fi
}

# =============================================================================
# Group Functions (for collapsible sections in GitHub Actions)
# =============================================================================

log_group() {
    local title="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::group::$title"
    else
        echo ""
        echo "--- ${title} $(printf '%0.s-' $(seq 1 $((60 - ${#title}))))"
    fi
}

log_group_end() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::endgroup::"
    else
        echo ""
    fi
}

# =============================================================================
# Banner Function (single-line pipeline header)
# =============================================================================

log_banner() {
    local title="$1"
    echo ""
    echo "==============================================================================="
    echo "$title"
    echo "==============================================================================="
    echo ""
}

# =============================================================================
# Mask sensitive values
# =============================================================================

log_mask() {
    local value="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::add-mask::$value"
    fi
}

# =============================================================================
# Set output (GitHub Actions compatible)
# =============================================================================

set_output() {
    local name="$1"
    local value="$2"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        # Check if value contains newlines - use heredoc format if so
        if [[ "$value" == *$'\n'* ]]; then
            {
                echo "${name}<<EOF"
                echo "$value"
                echo "EOF"
            } >> "$GITHUB_OUTPUT"
        else
            echo "$name=$value" >> "$GITHUB_OUTPUT"
        fi
    else
        echo "OUTPUT: $name=$value"
    fi
}
