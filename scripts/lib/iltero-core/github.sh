#!/bin/bash
# =============================================================================
# Iltero Core - GitHub Actions Helpers
# =============================================================================
# Functions for GitHub Actions integration, dependency sorting, and rich
# summary generation with markdown tables.
# =============================================================================

# Set GitHub Actions output
# Args: $1=name $2=value
set_output() {
    local name="$1"
    local value="$2"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${name}=${value}" >> "$GITHUB_OUTPUT"
    fi
}

# Set multiple outputs from scan results
set_scan_outputs() {
    set_output "passed" "$SCAN_PASSED"
    set_output "run-id" "$SCAN_RUN_ID"
    set_output "violations" "$SCAN_VIOLATIONS"
}

# Set multiple outputs from evaluation results
set_eval_outputs() {
    set_output "passed" "$EVAL_PASSED"
    set_output "run-id" "$EVAL_RUN_ID"
    set_output "violations" "$EVAL_VIOLATIONS"
    set_output "approval-id" "$APPROVAL_ID"
}

# Set multiple outputs from deployment results
set_deploy_outputs() {
    set_output "success" "$DEPLOY_SUCCESS"
    set_output "resources-count" "$RESOURCES_COUNT"
}

# Write content to GitHub Actions step summary
# Args: $1=content (markdown)
write_summary() {
    local content="$1"
    
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$content" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# Generate and write a compliance scan summary table
# Args: $1=scan_results_json (array of scan results)
write_scan_summary() {
    local results_json="$1"
    local title="${2:-Static Analysis Results}"
    
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0
    
    local summary=""
    summary+="## $title\n\n"
    summary+="| Unit | Status | High | Medium | Low | Scan ID |\n"
    summary+="|------|--------|------|--------|-----|----------|\n"
    
    # Parse each result and add row
    local rows
    rows=$(echo "$results_json" | jq -r '.[] | 
        "\(.unit_name // "unknown") | \(if .passed then "Pass" else "Fail" end) | \(.high // 0) | \(.medium // 0) | \(.low // 0) | `\(.scan_id // "N/A")`"')
    
    while IFS= read -r row; do
        summary+="| $row |\n"
    done <<< "$rows"
    
    # Add totals
    local total_high total_medium total_low
    total_high=$(echo "$results_json" | jq '[.[].high // 0] | add // 0')
    total_medium=$(echo "$results_json" | jq '[.[].medium // 0] | add // 0')
    total_low=$(echo "$results_json" | jq '[.[].low // 0] | add // 0')
    
    summary+="\n**Total Violations:** $total_high high, $total_medium medium, $total_low low\n"
    
    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Generate and write an evaluation summary table
# Args: $1=eval_results_json (array of evaluation results)
write_evaluation_summary() {
    local results_json="$1"
    local title="${2:-Plan Evaluation Results}"
    
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0
    
    local summary=""
    summary+="## $title\n\n"
    summary+="| Unit | Status | Resources | Violations | Approval ID |\n"
    summary+="|------|--------|-----------|------------|-------------|\n"
    
    local rows
    rows=$(echo "$results_json" | jq -r '.[] | 
        "\(.unit_name // "unknown") | \(if .passed then "Pass" else "Fail" end) | +\(.additions // 0)/-\(.deletions // 0)/~\(.changes // 0) | \(.violations // 0) | `\(.approval_id // "N/A")`"')
    
    while IFS= read -r row; do
        summary+="| $row |\n"
    done <<< "$rows"
    
    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Generate and write a deployment summary table
# Args: $1=deploy_results_json (array of deployment results)
write_deployment_summary() {
    local results_json="$1"
    local title="${2:-Deployment Results}"
    
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0
    
    local summary=""
    summary+="## $title\n\n"
    summary+="| Unit | Status | Resources | Duration |\n"
    summary+="|------|--------|-----------|----------|\n"
    
    local rows
    rows=$(echo "$results_json" | jq -r '.[] | 
        "\(.unit_name // "unknown") | \(if .success then "Pass" else "Fail" end) | \(.resource_count // 0) | \(.duration // "N/A")"')
    
    while IFS= read -r row; do
        summary+="| $row |\n"
    done <<< "$rows"
    
    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Generate a consolidated pipeline summary
# Args: $1=pipeline_results_json
#
# Accepts two formats:
#   Legacy: {"stack": "...", "environment": "...", "units": [...]}
#   New:    {"stacks": [...], "environment": "...", "unit_results": [...]}
#
# The new format uses the flat unit_results array from get_all_results().
write_pipeline_summary() {
    local results_json="$1"

    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0

    # Detect format: new format has "unit_results", legacy has "units"
    local is_new_format
    is_new_format=$(echo "$results_json" | jq 'has("unit_results")' 2>/dev/null || echo "false")

    if [[ "$is_new_format" == "true" ]]; then
        _write_pipeline_summary_v2 "$results_json"
    else
        _write_pipeline_summary_v1 "$results_json"
    fi
}

# Legacy pipeline summary (v1 format)
_write_pipeline_summary_v1() {
    local results_json="$1"

    local failed_count
    failed_count=$(echo "$results_json" | jq '[.units[] | select(.passed == false or .success == false)] | length')

    local overall_status
    local environment
    environment=$(echo "$results_json" | jq -r '.environment // "unknown"')

    if [[ "$failed_count" -eq 0 ]]; then
        overall_status="Passed"
    else
        overall_status="Failed"
    fi

    local stack_name
    stack_name=$(echo "$results_json" | jq -r '.stack // "unknown"')
    local unit_count
    unit_count=$(echo "$results_json" | jq '.units | length')

    local summary=""
    summary+="# Iltero Pipeline — ${environment}\n\n"
    summary+="**Result: ${overall_status}** | ${unit_count} units | Stack: ${stack_name}\n\n"

    # Unit details table
    summary+="## Unit Results\n\n"
    summary+="| Unit | Static Analysis | Plan Evaluation | Deploy |\n"
    summary+="|------|-----------------|-----------------|--------|\n"

    local rows
    rows=$(echo "$results_json" | jq -r '.units[] |
        "\(.name) | \(if .scan.passed then "Pass" elif .scan.skipped then "--" else "Fail" end) | \(if .evaluation.passed then "Pass" elif .evaluation.skipped then "--" else "Fail" end) | \(if .deploy.success then "Pass" elif .deploy.skipped then "--" else "Fail" end)"')

    while IFS= read -r row; do
        summary+="| $row |\n"
    done <<< "$rows"

    # Violations summary if any
    local total_violations
    total_violations=$(echo "$results_json" | jq '[.units[].scan.violations // 0, .units[].evaluation.violations // 0] | add // 0')

    if [[ "$total_violations" -gt 0 ]]; then
        summary+="\n### Violations\n\n"
        summary+="Total violations found: **$total_violations**\n\n"

        local units_with_violations
        units_with_violations=$(echo "$results_json" | jq -r '.units[] | select((.scan.violations // 0) > 0 or (.evaluation.violations // 0) > 0) | "- **\(.name)**: \((.scan.violations // 0) + (.evaluation.violations // 0)) violation(s)"')
        summary+="$units_with_violations\n"
    fi

    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Pipeline summary with eval mode and violation counts (v2 format)
# Args: $1=JSON with {stacks: [...], environment: "...", unit_results: [...]}
_write_pipeline_summary_v2() {
    local results_json="$1"

    local unit_results
    unit_results=$(echo "$results_json" | jq -c '.unit_results')

    local unit_count failed_count
    unit_count=$(echo "$unit_results" | jq 'length')
    failed_count=$(echo "$unit_results" | jq '[.[] | select(
        (.scan.passed == false and .scan.skipped != true) or
        (.evaluation.passed == false and .evaluation.skipped != true)
    )] | length')

    local environment stacks_csv
    stacks_csv=$(echo "$results_json" | jq -r '.stacks // [] | join(", ")')
    environment=$(echo "$results_json" | jq -r '.environment // "unknown"')

    local overall_status
    if [[ "$failed_count" -eq 0 ]]; then
        overall_status="Passed"
    else
        overall_status="Failed"
    fi

    local summary=""
    summary+="# Iltero Pipeline — ${environment}\n\n"
    summary+="**Result: ${overall_status}** | ${unit_count} units | Stacks: ${stacks_csv}\n\n"

    # Unit details table with eval mode column
    summary+="## Unit Results\n\n"
    summary+="| Unit | Static Analysis | Plan Evaluation | Eval Mode | Deploy |\n"
    summary+="|------|-----------------|-----------------|-----------|--------|\n"

    local has_best_effort=false
    local rows
    rows=$(echo "$unit_results" | jq -r '.[] |
        "\(.unit) | \(
            if .scan == null then "--"
            elif .scan.skipped then "Skip"
            elif .scan.passed then "Pass"
            else "Fail (\(.scan.violations // 0))"
            end
        ) | \(
            if .evaluation == null then "--"
            elif .evaluation.skipped then "Skip"
            elif .evaluation.passed then "Pass"
            else "Fail (\(.evaluation.violations // 0))"
            end
        ) | \(
            if .evaluation == null then "--"
            elif .evaluation.skipped then "--"
            else (.evaluation.eval_mode // "full")
            end
        ) | \(
            if .deploy == null then "--"
            elif .deploy.skipped then "Skip"
            elif .deploy.success then "Pass"
            else "Fail"
            end
        )"')

    while IFS= read -r row; do
        summary+="| $row |\n"
        if [[ "$row" == *"best_effort"* ]]; then
            has_best_effort=true
        fi
    done <<< "$rows"

    # Best-effort note
    if [[ "$has_best_effort" == "true" ]]; then
        summary+="\n> **Note:** Units evaluated in \`best_effort\` mode had unavailable upstream remote state. "
        summary+="Evaluation ran without backend data sources. Results may differ after upstream units deploy.\n"
    fi

    # Violations summary
    local total_scan_violations total_eval_violations total_violations
    total_scan_violations=$(echo "$unit_results" | jq '[.[].scan // {} | .violations // 0] | add // 0')
    total_eval_violations=$(echo "$unit_results" | jq '[.[].evaluation // {} | .violations // 0] | add // 0')
    total_violations=$((total_scan_violations + total_eval_violations))

    if [[ "$total_violations" -gt 0 ]]; then
        summary+="\n### Violations\n\n"
        summary+="| Phase | Violations |\n"
        summary+="|-------|------------|\n"
        summary+="| Static Analysis | $total_scan_violations |\n"
        summary+="| Plan Evaluation | $total_eval_violations |\n"
        summary+="| **Total** | **$total_violations** |\n\n"

        # Per-unit breakdown
        local units_with_violations
        units_with_violations=$(echo "$unit_results" | jq -r '.[] | select(
            ((.scan // {}).violations // 0) > 0 or ((.evaluation // {}).violations // 0) > 0
        ) | "- **\(.unit)**: \(((.scan // {}).violations // 0) + ((.evaluation // {}).violations // 0)) violation(s) (scan: \((.scan // {}).violations // 0), eval: \((.evaluation // {}).violations // 0))"')

        if [[ -n "$units_with_violations" ]]; then
            summary+="$units_with_violations\n"
        fi
    fi

    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Add a collapsible details section to summary
# Args: $1=title $2=content
write_summary_details() {
    local title="$1"
    local content="$2"
    
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] && return 0
    
    local summary=""
    summary+="<details>\n"
    summary+="<summary>$title</summary>\n\n"
    summary+="\`\`\`\n"
    summary+="$content\n"
    summary+="\`\`\`\n\n"
    summary+="</details>\n\n"
    
    echo -e "$summary" >> "$GITHUB_STEP_SUMMARY"
}

# Topological sort units by depends_on
# Args: $1=units_json (JSON array of units with name and depends_on)
# Outputs: Ordered JSON array to stdout
sort_units_by_dependency() {
    local units_json="$1"

    echo "$units_json" | python3 -c '
import json
import sys

units = json.load(sys.stdin)
graph = {u["name"]: u.get("depends_on", []) for u in units}
unit_map = {u["name"]: u for u in units}

visited = set()
stack = set()
result = []

def visit(node):
    if node in stack:
        print(f"ERROR: Circular dependency detected involving {node}", file=sys.stderr)
        sys.exit(1)
    if node in visited:
        return
    stack.add(node)
    for dep in graph.get(node, []):
        if dep not in graph:
            print(f"WARNING: Unknown dependency {dep} for {node}, skipping", file=sys.stderr)
            continue
        visit(dep)
    stack.remove(node)
    visited.add(node)
    result.append(unit_map[node])

for name in graph:
    visit(name)

print(json.dumps(result))
'
}
