#!/bin/bash
#
# check-comment-api-scope.sh
#
# Best-effort consumer-side guard for the `pull-requests: write` grant.
#
# The preview/compliance jobs grant the action `pull-requests: write` solely so
# it can post an advisory PR comment (the `/issues/{n}/comments` endpoint
# authorizes against the pull_requests scope when the numbered object is a PR).
# That scope ALSO permits review-create / approve / merge / base-edit — none of
# which this action needs. This check fails CI if any action definition reaches
# for those capabilities, keeping the token's residual power unused by our code
# so the grant cannot drift into a self-approval / auto-merge vector.
#
# The action may comment via the issues API (`issues.createComment`,
# `issues.updateComment`, `issues.listComments`); it must not call the PR
# review/merge surface.
#
# Scope/limits: this is a static grep against trusted first-party action YAML,
# meant to catch accidental drift — NOT an adversarial sandbox. It cannot catch
# dynamic dispatch (`github.rest.pulls[name](...)`) or arbitrary `github.request`
# URLs assembled at runtime. Anyone able to edit these files already controls the
# action; the guard exists to make an accidental review/merge call fail review.

set -euo pipefail

# Octokit method calls, GraphQL mutations, and REST paths that exceed "post a
# comment". Matched case-insensitively against every action.yml (github-script
# bodies are inline).
FORBIDDEN_PATTERNS=(
  'pulls\.merge'                  # merge the PR
  'pulls\.createReview'          # create/approve a review
  'pulls\.submitReview'          # submit (approve) a pending review
  'pulls\.dismissReview'         # dismiss a review
  'pulls\.updateReview'          # edit a review
  'pulls\.update\b'              # edit base branch / title / state
  'pulls\.requestReviewers'      # assign reviewers
  'pulls\.createReviewComment'   # diff-line review comment (not the issues API)
  'pulls/[^"'\''[:space:]]*/merge'    # REST: PUT .../pulls/{n}/merge
  'pulls/[^"'\''[:space:]]*/reviews'  # REST: POST .../pulls/{n}/reviews
  'mergePullRequest'             # GraphQL: merge mutation
  'enablePullRequestAutoMerge'   # GraphQL: enable auto-merge
  'PullRequestReview'            # GraphQL: add/submit review mutations
  'markPullRequestReadyForReview'  # GraphQL: ready-for-review mutation
)

action_files=()
for action in action.yml ./*/action.yml actions/*/action.yml; do
  [[ -f "${action}" ]] && action_files+=("${action}")
done

if [[ "${#action_files[@]}" -eq 0 ]]; then
  echo "::error::No action.yml files found to scan"
  exit 2
fi

violations=0
for action in "${action_files[@]}"; do
  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    while IFS= read -r match; do
      line_no="${match%%:*}"
      echo "::error file=${action},line=${line_no}::Forbidden PR review/merge API call (pattern: ${pattern}). This action may only post comments via the issues API."
      violations=$((violations + 1))
    done < <(grep -inE "${pattern}" "${action}" || true)
  done
done

if [[ "${violations}" -gt 0 ]]; then
  echo "::error::${violations} forbidden PR review/merge API usage(s) found. The 'pull-requests: write' grant exists only to post advisory comments."
  exit 1
fi

echo "OK: actions use only the comment API (no PR review/approve/merge/base-edit calls)."
