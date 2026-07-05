# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.4] - 2026-07-04

### Fixed

- A plan that changes no resources and defines no checks is now reported as
  **needs-review** with an actionable message (enable or add resources, then
  re-run) instead of a confusing "invalid plan" error, and the evaluator is not
  run for it — so no result is recorded for a unit with nothing to evaluate. A
  resource-less plan that still defines control checks is passed through to the
  evaluator rather than short-circuited.
- Plan evaluation now records a pass only when the evaluator produced results
  and evaluated at least one policy. A zero exit with nothing evaluated (missing
  results or an empty policy set) is treated as needs-review, never a pass.
- Evaluation verdicts are derived from the evaluator's exit code and confirmed-
  check count: a failing native Terraform `check{}` control now counts as a
  (waivable) violation even though it has no severity, an all-unknown result is
  needs-review, and only a genuine scanner/config/input error is an
  infrastructure error.

### Removed

- Unused `aggregation.sh` and `polling.sh` modules (dead code that invoked CLI
  subcommands that do not exist; never run by the pipeline).

## [0.1.3] - 2026-07-04

### Fixed

- Credential-less PR preview now drops IAM role assumption so `terraform plan`
  runs with no cloud credentials. Units whose `provider "aws"` sets a fixed
  `assume_role { role_arn = "..." }` previously failed preview with an STS
  "Cannot assume IAM Role" error, because the mock preview credentials cannot
  assume a real role. The provider override now includes an empty
  `assume_role {}`, which replaces the unit's block so no role is assumed and no
  STS call is made.

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
