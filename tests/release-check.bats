#!/usr/bin/env bats
#
# Tests for scripts/release-check.sh, which the Release workflow runs before
# it creates a tag.

load test_helper

setup() {
  make_runner
  export GITHUB_REF="refs/heads/main"
  SOURCES="${BATS_TEST_TMPDIR}/sources"
  # The CLI and schemas repositories, each with one commit on main and one
  # commit on another branch.
  local name
  for name in iltero-cli iltero-schemas; do
    git init -q -b main "${SOURCES}/${name}.git"
    git -C "${SOURCES}/${name}.git" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "on main"
    git -C "${SOURCES}/${name}.git" checkout -q -b feature
    git -C "${SOURCES}/${name}.git" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "not on main"
    git -C "${SOURCES}/${name}.git" checkout -q main
  done
  CHECKOUT="${BATS_TEST_TMPDIR}/checkout"
  mkdir -p "${CHECKOUT}/setup"
  cd "${CHECKOUT}" || return
  git init -q -b main
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "release candidate"
  pin_on_main
  cat > CHANGELOG.md << 'EOF'
# Changelog

## [Unreleased]

## [0.3.0] - 2026-11-20

### Added

- A new action.

## [0.2.0] - 2026-10-01

### Fixed

- An older fix.
EOF
  CHECK="${REPO_ROOT}/scripts/release-check.sh"
}

# Pins both repositories at their main commit.
pin_on_main() {
  {
    echo "iltero-schemas $(git -C "${SOURCES}/iltero-schemas.git" rev-parse main)"
    echo "iltero-cli $(git -C "${SOURCES}/iltero-cli.git" rev-parse main)"
  } > setup/cli-sources.txt
}

@test "a commit on main with a new version, its changelog section and pins on main can be released" {
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"v0.3.0 can be released."* ]]
}

@test "a release is made from main only" {
  GITHUB_REF="refs/heads/dev" run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"A release is made from the main branch only. This run is on 'refs/heads/dev'."* ]]
}

@test "a version that is not vMAJOR.MINOR.PATCH is refused" {
  local version
  for version in 0.3.0 v0.3 v0.3.0.1 "v0.3.0 " latest; do
    run "${CHECK}" check "${version}" "${SOURCES}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"The version must look like v1.2.3"* ]]
  done
}

@test "a version that already has a tag is refused" {
  git tag v0.3.0
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The tag v0.3.0 already exists."* ]]
}

@test "a version with no changelog section, or an empty one, is refused" {
  run "${CHECK}" check v0.4.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"CHANGELOG.md has no section for 0.4.0."* ]]
  printf '\n## [0.4.0] - 2026-12-01\n\n' >> CHANGELOG.md
  run "${CHECK}" check v0.4.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"CHANGELOG.md has no section for 0.4.0."* ]]
}

@test "a pre-release version with its own changelog section can be released" {
  printf '\n## [0.4.0-rc.1] - 2026-12-01\n\n- A candidate.\n' >> CHANGELOG.md
  run "${CHECK}" check v0.4.0-rc.1 "${SOURCES}"
  [ "${status}" -eq 0 ]
}

@test "a section heading for a longer version does not count for a shorter one" {
  sed -i.bak 's/## \[0.3.0\]/## [0.3.0-rc.1]/' CHANGELOG.md
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
}

@test "a pin that is not on its repository's main branch is refused" {
  echo "iltero-cli $(git -C "${SOURCES}/iltero-cli.git" rev-parse feature)" > setup/cli-sources.txt
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pins iltero-cli at"* ]]
  [[ "${output}" == *"which is not on the main branch of iltero-cli. Merge it there first."* ]]
}

@test "a repository that cannot be fetched stops the check, and its folder is removed" {
  echo "iltero-missing $(git -C "${SOURCES}/iltero-cli.git" rev-parse main)" > setup/cli-sources.txt
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${TMPDIR}"
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The release check could not fetch the main branch of iltero-missing"* ]]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "a pin file with a malformed line, or with no pin, is refused" {
  echo "iltero-cli main" > setup/cli-sources.txt
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"must be a repository name and a 40-character commit ID"* ]]
  : > setup/cli-sources.txt
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pins no repository"* ]]
}

@test "a pin file's last line counts even with no newline at its end" {
  printf 'iltero-cli %s' "$(git -C "${SOURCES}/iltero-cli.git" rev-parse feature)" > setup/cli-sources.txt
  run "${CHECK}" check v0.3.0 "${SOURCES}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"which is not on the main branch of iltero-cli"* ]]
}

@test "the release notes are the version's changelog section, and nothing else" {
  run "${CHECK}" notes v0.3.0
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"- A new action."* ]]
  [[ "${output}" != *"0.3.0] -"* ]]
  [[ "${output}" != *"An older fix."* ]]
}

@test "the release notes refuse a malformed version and a version with no section" {
  run "${CHECK}" notes "v1;x"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"The version must look like v1.2.3"* ]]
  run "${CHECK}" notes -x
  [ "${status}" -eq 1 ]
  run "${CHECK}" notes v0.9.0
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"CHANGELOG.md has no section for 0.9.0."* ]]
}

@test "the release is published only after the checks and CI pass, by a run started by hand" {
  local workflow="${REPO_ROOT}/.github/workflows/release.yml"
  grep -qx "  workflow_dispatch:" "${workflow}"
  ! grep -qE "^  (release|push):" "${workflow}" || false
  grep -qx "    needs: \[check, ci\]" "${workflow}"
  grep -qF 'scripts/release-check.sh check "${VERSION}"' "${workflow}"
  # The tag check sees every tag only with the full history.
  grep -qx "          fetch-depth: 0" "${workflow}"
}

@test "the release creates its tag at the checked commit first, and builds the release on that tag" {
  local workflow="${REPO_ROOT}/.github/workflows/release.yml"
  # The workflow's own text is matched as written.
  # shellcheck disable=SC2016
  grep -qF 'gh api "repos/${GITHUB_REPOSITORY}/git/refs" -f ref="refs/tags/${VERSION}" -f sha="${GITHUB_SHA}"' "${workflow}"
  grep -qF 'gh release create "${VERSION}" --verify-tag' "${workflow}"
  grep -qF '[[ "${VERSION}" != *-* ]] || release_kind=(--prerelease)' "${workflow}"
  [ "$(grep -c 'if: github.ref == '"'"'refs/heads/main'"'" "${workflow}")" -eq 2 ]
}

@test "the write token reaches only the step that creates the tag and the release" {
  local workflow="${REPO_ROOT}/.github/workflows/release.yml"
  [ "$(grep -c 'GH_TOKEN:' "${workflow}")" -eq 1 ]
  sed -n '/name: Write the release notes/,/name: Create the tag/p' "${workflow}" | { ! grep -q GH_TOKEN; }
}
