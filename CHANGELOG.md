# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-07-04

### Fixed

- Credential-less PR preview now completes `terraform plan` for units with a
  remote (S3) backend. Previously `init` ran with `-backend=false`, so `plan`
  aborted with "Backend initialization required"; preview now substitutes a
  local backend and plans against empty state with no cloud credentials. The
  credentialed deploy path is unchanged, and a preview still never enters the
  evidence/provenance chain.

## [0.1.1] - 2026-07-02

### Fixed

- PR-preview evaluation now runs `terraform plan` with no cloud credentials, so
  policies evaluate the plan JSON on every PR (including forks). Cloud-agnostic
  per-provider setup (AWS implemented); the credentialed deploy path is
  unchanged, and a preview never enters the evidence/provenance chain.

## [0.1.0] - 2026-06-26

### Added

- Initial release.
