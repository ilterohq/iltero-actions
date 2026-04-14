#!/bin/bash
# =============================================================================
# Iltero Actions - Generate Summary
# =============================================================================
# Generates a GitHub Actions step summary with pipeline results.
#
# Environment Variables (set by action.yml):
#   OVERALL_STATUS     - Overall pipeline status
#   STACKS_PROCESSED   - JSON array of processed stacks
#   COMPLIANCE_PASSED  - Whether compliance passed
#   EVALUATION_PASSED  - Whether evaluation passed
#   ENVIRONMENT        - Target environment
# =============================================================================

set -euo pipefail

# Get script directory for sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse inputs with defaults
STATUS="${OVERALL_STATUS:-unknown}"
STACKS="${STACKS_PROCESSED:-[]}"
COMPLIANCE="${COMPLIANCE_PASSED:-unknown}"
EVALUATION="${EVALUATION_PASSED:-unknown}"
ENV="${ENVIRONMENT:-unknown}"
UNIT_RESULTS_JSON="${UNIT_RESULTS:-}"

# Get stack count
STACK_COUNT=$(echo "$STACKS" | jq 'length' 2>/dev/null || echo "0")

# -------------------------------------------------------------------------
# Rich summary (when per-unit results are available)
# -------------------------------------------------------------------------
if [[ -n "$UNIT_RESULTS_JSON" ]] && echo "$UNIT_RESULTS_JSON" | jq empty 2>/dev/null; then
    # Source the iltero-core library for write_pipeline_summary
    source "${SCRIPT_DIR}/lib/iltero-core/index.sh"

    # Build the v2 pipeline summary JSON
    local_stacks_array="$STACKS"
    summary_json=$(jq -n \
        --argjson stacks "$local_stacks_array" \
        --arg environment "$ENV" \
        --argjson unit_results "$UNIT_RESULTS_JSON" \
        '{stacks: $stacks, environment: $environment, unit_results: $unit_results}')

    write_pipeline_summary "$summary_json"

    # Add timestamp
    cat >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}" << EOF

---
*Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC') by [Iltero Actions](https://github.com/ilterohq/iltero-actions)*
EOF
    exit 0
fi

# -------------------------------------------------------------------------
# Fallback: simple summary table (no per-unit data)
# -------------------------------------------------------------------------

# Determine status text
case "$STATUS" in
    success)
        STATUS_TEXT="Passed"
        ;;
    compliance_failed)
        STATUS_TEXT="Failed (static analysis)"
        ;;
    evaluation_failed)
        STATUS_TEXT="Failed (plan evaluation)"
        ;;
    deploy_failed)
        STATUS_TEXT="Failed (deploy)"
        ;;
    skipped)
        STATUS_TEXT="Skipped"
        ;;
    *)
        STATUS_TEXT="Unknown"
        ;;
esac

# Generate summary
cat >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}" << EOF
# Iltero Pipeline — $ENV

**Result: $STATUS_TEXT** | $STACK_COUNT stack(s) processed

## Summary

| Phase | Status |
|-------|--------|
| **Static Analysis** | $([ "$COMPLIANCE" == "true" ] && echo "Pass" || echo "Fail") |
| **Plan Evaluation** | $([ "$EVALUATION" == "true" ] && echo "Pass" || echo "Fail") |

EOF

# List processed stacks
if [[ "$STACK_COUNT" -gt 0 ]]; then
    cat >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}" << EOF
## Stacks Processed

EOF

    echo "$STACKS" | jq -r '.[]' 2>/dev/null | while read -r stack; do
        echo "- \`$stack\`" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
    done

    echo "" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
fi

# Add timestamp
cat >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}" << EOF
---
*Generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC') by [Iltero Actions](https://github.com/ilterohq/iltero-actions)*
EOF
