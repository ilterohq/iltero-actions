#!/bin/bash
#
# Posts the preview action's result as a comment on the pull request. Each
# preview keeps one comment, which this action updates on every push.
#
# Usage:
#   comment.sh check ARTIFACT_NAME             Refuse untrusted events and other events than pull_request.
#   comment.sh post ARTIFACT_NAME COMMENT_FILE  Create or update the comment.
#
# The job runs no code from the pull request, and needs only
# `pull-requests: write`. A pull request from a fork or from Dependabot gets a
# read-only token, so the action posts nothing for it and says so.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The account whose pull requests get a read-only token.
readonly DEPENDABOT_LOGIN="dependabot[bot]"
# Starts every comment this action writes. The artifact name and the
# workflow file follow it, so each preview keeps its own comment.
readonly MARKER_PREFIX="<!-- iltero-preview:"

cmd_check() {
  local name="$1"
  refuse_untrusted_event
  [[ "${GITHUB_EVENT_NAME}" == pull_request ]] \
    || die "The comment action runs only on pull_request events."
  check_artifact_name "${name}"
}

cmd_post() {
  local name="$1"
  local file="$2"
  check_artifact_name "${name}"
  [[ "${PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] || die "PR_NUMBER is not a pull request number."
  [[ -n "${GITHUB_REPOSITORY:-}" ]] || die "GITHUB_REPOSITORY is not set. Run this action inside a GitHub Actions job."
  if [[ "${HEAD_REPOSITORY:-}" != "${GITHUB_REPOSITORY}" ]]; then
    echo "::notice::This pull request comes from a fork, so its token cannot comment. See the job summary instead."
    return 0
  fi
  if [[ "${GITHUB_ACTOR:-}" == "${DEPENDABOT_LOGIN}" ]]; then
    echo "::notice::This pull request comes from Dependabot, so its token cannot comment. See the job summary instead."
    return 0
  fi
  [[ -f "${file}" ]] || die "The comment file is missing."
  [[ -n "${GITHUB_WORKFLOW_REF:-}" ]] || die "GITHUB_WORKFLOW_REF is not set. Run this action inside a GitHub Actions job."
  local workflow
  workflow="$(printf '%s' "${GITHUB_WORKFLOW_REF%%@*}" | sha256sum | cut -c1-12)"
  python3 "$(dirname "${BASH_SOURCE[0]}")/lib/pr_comment.py" "${MARKER_PREFIX}${name}:${workflow} -->" "${file}"
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) [[ $# -eq 1 ]] || die "Usage: comment.sh check ARTIFACT_NAME"; cmd_check "$@" ;;
    post) [[ $# -eq 2 ]] || die "Usage: comment.sh post ARTIFACT_NAME COMMENT_FILE"; cmd_post "$@" ;;
    *) die "Unknown command '${command}'. Use: check ARTIFACT_NAME | post ARTIFACT_NAME COMMENT_FILE" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
