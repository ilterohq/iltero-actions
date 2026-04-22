# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.2] - 2026-04-22

### Fixed

- Pass `-backend-config` to `terraform init` during plan evaluation

## [1.3.1] - 2026-04-17

### Added

- Per-stack OIDC exchange — multi-stack repos get a correctly scoped token per stack
- Stack-level error tracking — OIDC or config failures now fail the pipeline instead of silently passing

### Removed

- `stack_id` input from the root action (read from each stack's `config.yml`)

## [1.3.0] - 2026-04-16

### Added

- OIDC audience auto-derivation from the API URL host
- Preflight check for `id-token: write` workflow permission
- Shared `scripts/oidc-exchange.sh` used by root and `setup-oidc` actions

### Changed

- Deploy authorization uses the updated Iltero CLI command

### Docs

- Document deploy-gate contract in `docs/authentication.md`
- Remove stale CLI references from approval docs and examples

## [1.2.0] - 2026-04-14

### Fixed

- Resolve PR environment from base branch and fail closed when no `git_ref` matches

### Added

- `compliance_only` output (true on `pull_request` events)
- `examples/workflow-security.yml` — drop-in zizmor workflow
- Pinning guidance and Dependabot config in docs

### Changed

- Rename scan phases: "Compliance Scan" → "Static Analysis"
- Split README into focused `docs/` pages
- Broaden positioning from Terraform-specific to IaC

### Security

- Pin all actions to commit SHAs in examples
- Close shell injection vectors in example workflows

## [1.1.3] - 2026-04-13

### Fixed

- Stacks path validation and handling

## [1.1.2] - 2026-04-06

### Changed

- Bump pinned actions to Node.js 24-compatible versions

## [1.1.1] - 2026-04-05

### Changed

- Consolidate composite actions in root `action.yml`

## [1.1.0] - 2026-03-26

### Added

- Scan results processing enhancements

## [1.0.1] - 2026-03-01

### Fixed

- Minor fixes following initial release

## [1.0.0] - 2026-02-24

### Added

- Initial release
