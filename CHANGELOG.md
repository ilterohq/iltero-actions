# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The Terraform version is now set only via the `terraform_version` input (or
  the default, newest 1.10.x). `config.yml terraform.version` is no longer read
  for installation, so a stale value there cannot force an unsupported version.

## [0.1.9] - 2026-07-18

### Added

- Terraform version selection. Set `terraform_version` on the action (an exact
  version, `latest`, or a constraint like `~> 1.11`) or `terraform.version` in
  `config.yml`; the action input takes precedence. The version is resolved
  before install so `config.yml` can drive it. Terraform-style constraints are
  accepted and normalized to what `setup-terraform` expects.
- The installed Terraform version is enforced to be >= 1.10 (required for S3
  native state locking, `use_lockfile`). The job fails closed below it — checked
  both right after install and again before every plan/apply/refresh, so all
  entrypoints (the root action and the granular scan/evaluate/deploy/monitor
  actions) are covered.
- The concrete Terraform version used is exposed as the `terraform_version`
  action output and shown in the run summary (a range resolves to a specific
  patch), for the audit trail.
- Clearer error when a unit's state was written by a newer Terraform than the
  installed version, pointing at the version to raise.

### Changed

- Default Terraform version is now the newest 1.10.x (was 1.5.7). Pin
  `terraform_version` or `terraform.version` to keep a specific version.
- A job whose selected stacks pin different `terraform.version` values now fails
  closed; pin an explicit version or split the stacks.

## [0.1.8] - 2026-07-18

### Fixed

- Plan-mode static scanning left the unit's backend and variable files
  unresolved when `stacks_path` was relative, so `terraform init` ran without a
  backend config and failed. The unit path is now resolved before use.
- Compliance plans (scan and evaluate) run without taking a Terraform state
  lock. These plans are read-only and are never applied, so they no longer
  require the backend's state-lock resource (e.g. a DynamoDB lock table) to
  exist. Deployment still locks as before.

## [0.1.7] - 2026-07-13

### Fixed

- `setup-oidc` failed at its registry-configuration step when used as a remote
  action: it referenced a local action path that resolved against the caller's
  checkout instead of the action's own directory. Registry setup is now inlined
  so it works remotely. Affects any consumer using `setup-oidc` with the default
  `configure-registry: true`.

## [0.1.6] - 2026-07-13

### Fixed

- `resolve-credentials` resolves the cloud role at run time instead of relying
  on a role hard-coded in the workflow. It takes a `workspace-id` or `stack-id`,
  detects `environment` from `config.yml` when omitted, and adds a
  `role-duration-seconds` input (default 900).
- `setup-oidc` adds a repo-scoped mode (`workspace-id`) for a job-level lookup
  before any stack is selected. Exactly one of `workspace-id`/`stack-id` is
  required.
- Credential resolution retries transient failures (rate limit, network, 5xx)
  and fails fast on auth/not-found errors with an actionable message.
- Environment detection now fails closed on a malformed config instead of
  treating it as "no environment" and skipping.

Requires an Iltero CLI providing `iltero environment detect` (`setup` installs
the latest by default).

## [0.1.5] - 2026-07-05

### Fixed

- The advisory pull-request comment reported only violation counts, so users
  could not tell what failed or why. It now lists the actual findings: each one
  shows its severity, the control it maps to (e.g. a SOC 2 requirement and the
  underlying CIS AWS control), a plain-language detail, and — for static
  findings — the file, line, and a link to remediation docs. Findings are split
  into **blocking** (at or above the environment's fail-on severity, plus any
  failed native Terraform `check{}` control, which previously did not appear at
  all) and **below threshold** (shown for awareness), and the comment names the
  active threshold so a passing "N violations" count is no longer ambiguous.
  Per-unit detail is collapsible so the comment stays readable from zero
  findings up to many.
- Scan results were not downloadable. Every run now uploads a **scan results**
  artifact with the full, sanitized findings for all units (runner-absolute
  paths stripped, raw Terraform plan excluded).

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
