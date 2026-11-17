#!/bin/bash
#
# Checks that a commit can be released, and prints a release's notes. The
# Release workflow runs it before it creates the tag, so nothing is published
# unless every check passes. Run it from the repository root.
#
# Usage:
#   release-check.sh check VERSION SOURCES_URL
#       Succeeds when the run is on main, VERSION is vMAJOR.MINOR.PATCH (with
#       an optional pre-release or build suffix), no tag VERSION exists yet,
#       CHANGELOG.md has a section for VERSION, and each commit that
#       setup/cli-sources.txt pins is on the main branch of its repository,
#       found at SOURCES_URL/<name>.git.
#   release-check.sh notes VERSION
#       Prints the body of CHANGELOG.md's section for VERSION.
#
# Environment:
#   GITHUB_REF   The branch the run is on (check only).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# The form of a release version.
readonly RELEASE_VERSION_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?(\+[A-Za-z0-9.]+)?$'
# The branch every release is made from.
readonly RELEASE_BRANCH="main"
readonly CHANGELOG_FILE="CHANGELOG.md"
readonly PINNED_SOURCES_FILE="setup/cli-sources.txt"

# Stops unless VERSION has the form of a release version.
require_release_version() {
  [[ "$1" =~ ${RELEASE_VERSION_PATTERN} ]] \
    || die "The version must look like v1.2.3, with an optional suffix such as -rc.1. It is '$1'."
}

# Prints the body of CHANGELOG.md's section for VERSION: the lines after its
# "## [X.Y.Z]" heading, up to the next "## " heading. Fails when there is no
# such section, or when it is empty.
changelog_section() {
  local number="${1#v}"
  awk -v heading="## [${number}]" '
    index($0, heading) == 1 && (length($0) == length(heading) || substr($0, length(heading) + 1, 1) == " ") {
      inside = 1
      next
    }
    inside && /^## / { exit }
    inside { print; if ($0 ~ /[^[:space:]]/) found = 1 }
    END { exit found ? 0 : 1 }
  ' "${CHANGELOG_FILE}"
}

# Stops unless COMMIT is on the main branch of the repository at URL. Fetches
# it into a new folder under PARENT.
require_on_main() {
  local name="$1" commit="$2" url="$3" parent="$4"
  local clone="${parent}/${name}"
  git init -q "${clone}"
  git -C "${clone}" fetch -q --filter=blob:none "${url}" "${RELEASE_BRANCH}" \
    || die "The release check could not fetch the ${RELEASE_BRANCH} branch of ${name} from ${url}."
  git -C "${clone}" merge-base --is-ancestor "${commit}" FETCH_HEAD 2> /dev/null \
    || die "${PINNED_SOURCES_FILE} pins ${name} at ${commit}, which is not on the ${RELEASE_BRANCH} branch of ${name}. Merge it there first."
}

cmd_check() {
  local version="$1" sources_url="$2"
  [[ "${GITHUB_REF:-}" == "refs/heads/${RELEASE_BRANCH}" ]] \
    || die "A release is made from the ${RELEASE_BRANCH} branch only. This run is on '${GITHUB_REF:-}'."
  require_release_version "${version}"
  ! git rev-parse -q --verify "refs/tags/${version}" > /dev/null \
    || die "The tag ${version} already exists. Choose a new version."
  changelog_section "${version}" > /dev/null \
    || die "${CHANGELOG_FILE} has no section for ${version#v}. Add a '## [${version#v}]' section that lists the changes."
  [[ -f "${PINNED_SOURCES_FILE}" ]] || die "${PINNED_SOURCES_FILE} is missing."
  # The repositories are fetched into one folder, removed however the check
  # ends.
  local clones
  clones="$(mktemp -d)"
  # shellcheck disable=SC2064 # The folder is fixed when the trap is set.
  trap "rm -rf '${clones}'" EXIT
  local name commit extra found=0
  while read -r name commit extra || [[ -n "${name}" ]]; do
    [[ -n "${name}" ]] || continue
    [[ "${name}" =~ ^[a-z0-9-]+$ && "${commit}" =~ ^[0-9a-f]{40}$ && -z "${extra}" ]] \
      || die "Each line of ${PINNED_SOURCES_FILE} must be a repository name and a 40-character commit ID."
    require_on_main "${name}" "${commit}" "${sources_url}/${name}.git" "${clones}"
    found=$((found + 1))
  done < "${PINNED_SOURCES_FILE}"
  [[ "${found}" -gt 0 ]] || die "${PINNED_SOURCES_FILE} pins no repository."
  echo "${version} can be released."
}

cmd_notes() {
  local version="$1"
  require_release_version "${version}"
  changelog_section "${version}" || die "${CHANGELOG_FILE} has no section for ${version#v}."
}

main() {
  local command="${1:-}"
  shift || true
  case "${command}" in
    check) [[ $# -eq 2 ]] || die "Usage: release-check.sh check VERSION SOURCES_URL"; cmd_check "$@" ;;
    notes) [[ $# -eq 1 ]] || die "Usage: release-check.sh notes VERSION"; cmd_notes "$@" ;;
    *) die "Unknown command '${command}'. Use: check VERSION SOURCES_URL | notes VERSION" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
