#!/bin/bash
# =============================================================================
# Iltero Core - Reporting (PR findings + downloadable artifact)
# =============================================================================
# Turns the CLI's on-disk per-unit result JSON into two additive outputs:
#   1. A sanitized artifact tree under the report dir, uploaded via
#      actions/upload-artifact so users can download the full finding set.
#   2. A bounded, severity-sorted findings file that the advisory PR comment
#      reads directly from the workspace. The comment step shares this
#      filesystem, so enriched findings never travel through a GitHub Actions
#      step output (which has a size limit and mangles multi-line values).
#
# Sanitization is an ALLOWLIST projection: only known-safe fields survive, so a
# field the CLI might add later cannot leak by default. file_path is
# relativized so runner-absolute paths never appear. The raw terraform plan
# JSON is never read or copied here.
#
# Failure-soft: every public function runs under `set +e` and always returns 0.
# Reporting is advisory and must never fail a compliance run.
#
# Reads the same on-disk CLI JSON that scanning.sh / evaluation.sh write:
#   ${STACKS_CONFIG}/{stack}/static/static-{unit}-<ts>.json
#   ${STACKS_CONFIG}/{stack}/evaluation/evaluation-{unit}-<ts>.json
# It does NOT touch results.json, append_unit_result, or the unit_results
# output — existing consumers are unaffected.
# =============================================================================

# Prevent double-sourcing
if [[ -n "${ILTERO_REPORTING_SOURCED:-}" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
export ILTERO_REPORTING_SOURCED=1

# Shared jq prelude: the allowlist projection plus a severity-rank helper.
# project($ws) maps one raw violation (static OR eval — they share a top-level
# shape) to the sanitized shape. OPA-only fields (control_key, framework
# mapping) are pulled from metadata.opa_raw when present. file_path is stripped
# of the workspace prefix with ltrimstr (literal, not regex).
# remediation_url keeps only a single clean URL (static findings link to docs);
# the multi-line remediation prose that OPA findings carry is dropped from this
# projection to keep the comment compact — the full text stays in the raw file,
# which is not published.
# shellcheck disable=SC2016  # $ws et al. are jq variables, not shell expansions
_ILTERO_VIOLATION_JQ='
def sevrank($s): ({"critical":4,"high":3,"medium":2,"low":1}[$s]) // 0;
def project($ws; $pwd):
  {
    kind: "policy",
    check_id: .check_id,
    check_name: (.check_name // .check_id),
    severity: (.severity // "unknown"),
    resource: (.resource // null),
    file_path: (((.file_path // "") | ltrimstr($ws) | ltrimstr($pwd) | ltrimstr("/")) as $p
                | if ($p == "" or ($p | endswith("tfplan.json"))) then null else $p end),
    line: (.line_range[0]? // null),
    description: ((.description // .metadata.opa_raw.message // "") | gsub("^\\s+"; "")),
    framework: (.framework // null),
    control_key: (.metadata.opa_raw.control_key // null),
    soc2_controls: (.metadata.opa_raw.framework_controls.SOC2 // .metadata.control_ids // []),
    remediation_url: ((.remediation // "")
                      | if test("^https?://[^[:space:]]+$") then . else null end)
  };
# Failing native check{} blocks. These carry NO severity (any failing native
# check is a compliance failure regardless of severity), no file, and no
# remediation — just the control name and per-instance pass/fail. Kept as a
# distinct kind so the comment can render and always-block them correctly.
def project_native:
  ((.instance_statuses // []) | map(select(. == "fail")) | length) as $failed
  | ((.instance_statuses // []) | length) as $total
  | {
    kind: "native_check",
    check_id: .name,
    check_name: .name,
    severity: "none",
    resource: null,
    file_path: null,
    line: null,
    description: (if $total > 0 then "Native check failed (\($failed) of \($total) instance(s))"
                  else "Native check failed" end),
    framework: null,
    control_key: null,
    soc2_controls: [],
    remediation_url: null
  };
'

# _report_stacks_base
# Absolute path to the per-stack results tree the CLI wrote this run.
# Prefer ILTERO_RESULTS_BASE (captured by results.sh at init time) so we read
# exactly where the CLI wrote, even if the working directory moved since; fall
# back to the same $(pwd)/${STACKS_CONFIG} construction results.sh uses.
_report_stacks_base() {
    if [[ -n "${ILTERO_RESULTS_BASE:-}" ]]; then
        printf '%s' "${ILTERO_RESULTS_BASE}"
    else
        printf '%s/%s' "$(pwd)" "${STACKS_CONFIG:-.iltero/stacks}"
    fi
}

# _report_unit_from_file <phase> <path>
# Extract the unit name from a "{phase}-{unit}-{ts}.json" filename. The unit may
# contain hyphens; the trailing "-<digits>.json" timestamp anchors the split.
_report_unit_from_file() {
    local phase="$1"
    local path="$2"
    basename "${path}" | sed -E "s/^${phase}-(.+)-[0-9]+\\.json$/\\1/"
}

# assemble_report_artifact <report_dir> [environment] [threshold]
# Build the sanitized, downloadable artifact tree under <report_dir>:
#   <report_dir>/manifest.json
#   <report_dir>/stacks/{stack}/{unit}/{static,evaluation}.json
# Each per-unit file is self-describing ({stack, unit, phase, findings:[...]})
# so build_pr_findings can merge them without re-parsing paths.
assemble_report_artifact() {
    local report_dir="${1:?report dir required}"
    local environment="${2:-unknown}"
    local threshold="${3:-high}"

    # Run the whole body in a subshell so failure-soft handling (`set +e`, a
    # mid-way error) is fully contained and never leaks errexit back to the
    # caller (run-pipeline.sh runs under `set -euo pipefail`). Inside the
    # subshell, early exits use `exit 0`, not `return`. Always returns 0.
    (
        set +e

        local base ws pwd_abs
        base="$(_report_stacks_base)"
        pwd_abs="$(pwd)"
        ws="${GITHUB_WORKSPACE:-${pwd_abs}}"

        mkdir -p "${report_dir}/stacks" || exit 0

        if [[ ! -d "${base}" ]]; then
            log_debug "reporting: no stacks base at ${base}; nothing to assemble"
            exit 0
        fi

        local stack_dir stack phase pdir f unit out_dir
        for stack_dir in "${base}"/*/; do
            [[ -d "${stack_dir}" ]] || continue
            stack="$(basename "${stack_dir}")"
            for phase in static evaluation; do
                pdir="${stack_dir}${phase}"
                [[ -d "${pdir}" ]] || continue

                # Newest file first so the first occurrence of each unit wins (a
                # unit re-scanned in the same run would otherwise appear twice).
                # Track seen units in a space-delimited string for portability
                # (no associative arrays; works on bash 3.2+).
                local seen_units=" "
                local listing
                # shellcheck disable=SC2012  # ls -t for mtime ordering; names are controlled
                listing="$(ls -t "${pdir}/${phase}-"*.json 2>/dev/null)"
                [[ -n "${listing}" ]] || continue

                while IFS= read -r f; do
                    [[ -f "${f}" ]] || continue
                    unit="$(_report_unit_from_file "${phase}" "${f}")"
                    [[ -n "${unit}" ]] || continue
                    case "${seen_units}" in *" ${unit} "*) continue ;; esac
                    seen_units="${seen_units}${unit} "

                    out_dir="${report_dir}/stacks/${stack}/${unit}"
                    mkdir -p "${out_dir}" || continue
                    # Evaluation files also carry failing native check{} blocks
                    # (no severity); static files never do.
                    # shellcheck disable=SC2016  # jq program body; $-vars are jq, not shell
                    local project_body='
                            {stack: $stack, unit: $unit, phase: $phase,
                             findings: (
                               [(.violations // [])[] | project($ws; $pwd)]
                               + (if $phase == "evaluation"
                                  then [(.native_checks // [])[] | select(.status == "fail") | project_native]
                                  else [] end)
                             )}'
                    if ! jq --arg ws "${ws}" --arg pwd "${pwd_abs}" --arg stack "${stack}" \
                            --arg unit "${unit}" --arg phase "${phase}" \
                            "${_ILTERO_VIOLATION_JQ}${project_body}" \
                            "${f}" > "${out_dir}/${phase}.json" 2>/dev/null; then
                        log_debug "reporting: could not project ${f}"
                        rm -f "${out_dir}/${phase}.json"
                    fi
                done <<< "${listing}"
            done
        done

        jq -n --arg env "${environment}" --arg threshold "${threshold}" \
              --arg run_id "${GITHUB_RUN_ID:-}" --arg sha "${GITHUB_SHA:-}" \
              --arg repo "${GITHUB_REPOSITORY:-}" \
              '{environment: $env, severity_threshold: $threshold,
                run_id: $run_id, commit: $sha, repository: $repo,
                note: "Sanitized advisory scan results. Runner-absolute paths and the raw Terraform plan are excluded."}' \
              > "${report_dir}/manifest.json" 2>/dev/null || true

        log_debug "reporting: artifact assembled at ${report_dir}"
    )
    return 0
}

# build_pr_findings <report_dir> [threshold] [max_findings]
# Merge the sanitized per-unit files into a single bounded, severity-sorted
# findings file the PR comment reads: <report_dir>/pr-findings.json
#
# Each finding is tagged with stack/unit/phase and a `blocking` flag (severity
# at or above <threshold> — the gate-failing set; a finding with no/unknown
# severity is treated as blocking so it is never hidden). The displayed list is
# capped at <max_findings> with blocking findings kept first; `truncated` is
# true only when something was actually dropped. `by_unit` and `total*` carry
# the TRUE counts regardless of the display cap, so the comment can say "N of M".
build_pr_findings() {
    local report_dir="${1:?report dir required}"
    local threshold="${2:-high}"
    local max_findings="${3:-50}"

    # Subshell contains failure-soft handling; never leaks errexit. Always 0.
    (
        set +e

        local out="${report_dir}/pr-findings.json"
        local -a unit_files=()
        local uf
        while IFS= read -r uf; do
            [[ -n "${uf}" ]] && unit_files+=("${uf}")
        done < <(find "${report_dir}/stacks" -type f -name '*.json' 2>/dev/null | sort)

        if [[ ${#unit_files[@]} -eq 0 ]]; then
            log_debug "reporting: no sanitized unit files; skipping pr-findings"
            exit 0
        fi

        # Merge every finding, tag blocking (unknown severity → blocking), sort
        # blocking-first by severity, and cap the DISPLAY list at $max (blocking
        # prioritized). jq -s slurps all per-unit files.
        # shellcheck disable=SC2016  # jq program body; $-vars are jq, not shell
        local merge_body='
            (map(
                (.stack) as $stack | (.unit) as $unit | (.phase) as $phase
                | (.findings // [])[]
                | . + {stack: $stack, unit: $unit, phase: $phase,
                       blocking: ((.kind == "native_check")
                                  or (sevrank(.severity) >= sevrank($threshold)))}
            )) as $all
            | ($all | map(select(.blocking))
                     | sort_by(-sevrank(.severity))) as $blocking
            | ($all | map(select(.blocking | not))
                     | sort_by(-sevrank(.severity))) as $below
            | ($all | group_by(.stack + " " + .unit) | map({
                  stack: .[0].stack,
                  unit: .[0].unit,
                  blocking: (map(select(.blocking)) | length),
                  below: (map(select(.blocking | not)) | length)
              })) as $by_unit
            | {
                threshold: $threshold,
                total: ($all | length),
                total_blocking: ($blocking | length),
                total_below: ($below | length),
                truncated: (($all | length) > $max),
                by_unit: $by_unit,
                findings: (($blocking + $below)[0:$max])
              }'
        if ! jq -s --arg threshold "${threshold}" --argjson max "${max_findings}" \
                "${_ILTERO_VIOLATION_JQ}${merge_body}" \
                "${unit_files[@]}" > "${out}" 2>/dev/null; then
            log_debug "reporting: failed to build pr-findings"
            rm -f "${out}"
            exit 0
        fi

        log_debug "reporting: pr-findings written to ${out}"
    )
    return 0
}
