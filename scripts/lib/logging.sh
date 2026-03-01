#!/bin/bash
# =============================================================================
# Iltero Actions - Logging Library
# =============================================================================
# Provides consistent logging functions for the pipeline scripts.
# Uses GitHub Actions workflow commands for proper formatting.
# =============================================================================

# Colors (only used when not in GitHub Actions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Logging Functions
# =============================================================================

log_info() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "ℹ️  $message"
    else
        echo -e "${BLUE}ℹ️  $message${NC}"
    fi
}

log_success() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "✅ $message"
    else
        echo -e "${GREEN}✅ $message${NC}"
    fi
}

log_warning() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::warning::$message"
    else
        echo -e "${YELLOW}⚠️  $message${NC}"
    fi
}

log_error() {
    local message="$1"
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::error::$message"
    else
        echo -e "${RED}❌ $message${NC}"
    fi
}

log_debug() {
    local message="$1"
    if [[ "${DEBUG:-}" == "true" ]]; then
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::debug::$message"
        else
            echo "🔍 DEBUG: $message"
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
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$title"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
# Banner Function
# =============================================================================

log_banner() {
    local title="$1"
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    printf "║ %-58s ║\n" "$title"
    echo "╚════════════════════════════════════════════════════════════╝"
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
