#!/usr/bin/env bash
# =============================================================================
# Local Test Runner
# =============================================================================
# Run all tests and linting locally before pushing.
#
# Usage:
#   ./scripts/test.sh          # Run all checks
#   ./scripts/test.sh lint     # Only linting
#   ./scripts/test.sh unit     # Only unit tests
#   ./scripts/test.sh syntax   # Only syntax checks
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helpers
# =============================================================================

log_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command not found: $1"
        echo "  Install with: $2"
        return 1
    fi
    return 0
}

# =============================================================================
# Checks
# =============================================================================

run_syntax_check() {
    log_header "Bash Syntax Check"
    
    local failed=0
    while IFS= read -r -d '' script; do
        if bash -n "$script" 2>/dev/null; then
            log_success "$script"
        else
            log_error "$script"
            bash -n "$script" 2>&1 | sed 's/^/    /'
            ((failed++))
        fi
    done < <(find "$PROJECT_ROOT/scripts" -name '*.sh' -type f -print0)
    
    if [[ $failed -gt 0 ]]; then
        log_error "Syntax check failed: $failed file(s) with errors"
        return 1
    fi
    log_success "All syntax checks passed"
}

run_shellcheck() {
    log_header "ShellCheck Linting"
    
    if ! check_command shellcheck "brew install shellcheck (macOS) or apt install shellcheck (Ubuntu)"; then
        return 1
    fi
    
    local failed=0
    while IFS= read -r -d '' script; do
        if shellcheck --severity=warning "$script" 2>/dev/null; then
            log_success "$script"
        else
            log_error "$script"
            shellcheck --severity=warning --format=tty "$script" 2>&1 | sed 's/^/    /'
            ((failed++))
        fi
    done < <(find "$PROJECT_ROOT/scripts" -name '*.sh' -type f -print0)
    
    if [[ $failed -gt 0 ]]; then
        log_error "ShellCheck found issues in $failed file(s)"
        return 1
    fi
    log_success "All files passed ShellCheck"
}

run_unit_tests() {
    log_header "Bats Unit Tests"
    
    if ! check_command bats "brew install bats-core (macOS) or apt install bats (Ubuntu)"; then
        log_warning "Skipping unit tests - bats not installed"
        return 0
    fi
    
    local test_dir="$PROJECT_ROOT/tests"
    
    if [[ ! -d "$test_dir" ]] || [[ -z "$(ls -A "$test_dir"/*.bats 2>/dev/null)" ]]; then
        log_warning "No test files found in $test_dir"
        return 0
    fi
    
    cd "$PROJECT_ROOT"
    if bats --tap tests/*.bats; then
        log_success "All unit tests passed"
    else
        log_error "Unit tests failed"
        return 1
    fi
}

run_yaml_lint() {
    log_header "YAML Lint"
    
    if ! check_command yamllint "pip install yamllint"; then
        log_warning "Skipping YAML lint - yamllint not installed"
        return 0
    fi
    
    local config="$PROJECT_ROOT/.yamllint.yml"
    if [[ -f "$config" ]]; then
        yamllint -c "$config" "$PROJECT_ROOT" && log_success "YAML lint passed" || {
            log_error "YAML lint failed"
            return 1
        }
    else
        log_warning "No .yamllint.yml found, using defaults"
        yamllint "$PROJECT_ROOT" && log_success "YAML lint passed" || return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    local mode="${1:-all}"
    local exit_code=0
    
    case "$mode" in
        lint)
            run_shellcheck || exit_code=1
            run_yaml_lint || exit_code=1
            ;;
        unit)
            run_unit_tests || exit_code=1
            ;;
        syntax)
            run_syntax_check || exit_code=1
            ;;
        all|*)
            run_syntax_check || exit_code=1
            run_shellcheck || exit_code=1
            run_unit_tests || exit_code=1
            ;;
    esac
    
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        log_header "All Checks Passed ✓"
    else
        log_header "Some Checks Failed ✗"
    fi
    
    return $exit_code
}

main "$@"
