# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-18

### Breaking

Each of these is intended. In every case the previous behaviour reported success
over something it had not established.

- **A check that produced no verdict is no longer waivable.**
  `block_on_violations: false` says an operator has seen the findings and accepts
  them. Missing tooling, policies that could not be fetched, an unreadable plan,
  bad input and results the service never recorded produce no findings to accept,
  so they now block. Workspaces setting `block_on_violations: false` whose policy
  resolution fails were previously warned and deployed. This requires Iltero CLI
  0.7.0 or newer, which is the first version to report those states as errors
  rather than exiting cleanly.
- **A `config-path` that does not exist, or does not declare the environment
  being scanned, now fails the run** instead of scanning against no compliance
  frameworks and passing.
- **A `frameworks` value written as a single item rather than a list now fails**
  instead of silently becoming "no frameworks".
- **The deployment authorization check refuses to run when the Iltero CLI path
  was not recorded at setup.** Workflows that install the CLI themselves and call
  the deploy action without the setup action are blocked; run the setup action,
  or set `ILTERO_CLI_BIN`.
- **Installing the CLI fails when the resolved binary sits outside the Python
  environment the action installed into.** A runner image carrying its own Iltero
  CLI needs that copy removed, or the setup action's Python setup used.
- **A failed tool install now fails the job.** It was previously reported as a
  successful install, leaving the run to continue with the wrong version or no
  scanner at all.
- **The Terraform version is no longer read from `config.yml`.** It comes from
  the `terraform_version` input, or the default (newest 1.10.x). `terraform`
  in `config.yml` was honoured from 0.1.9; a value left there from before the
  1.10 floor forced an unsupported install and failed the job, with no way out
  except editing the stack's tracked configuration. A stack that declares a
  version above the floor will now get the default instead, so move any version
  you rely on to the `terraform_version` input.
- **An environment name containing `*` or `?` is now rejected.** Those are
  matched as patterns, so such a name answered with another environment's
  settings.
- **The Iltero CLI is now pinned by default (0.7.1), and must be 0.7.0 or newer.** All
  three actions that install it previously took the newest release on every run.
  A CLI release can change what blocks a deployment, so the version is now an
  explicit choice; `cli_version` (or `version`) overrides it. Below 0.7.0 the
  CLI exits cleanly when a scan reached no compliance verdict, which this action
  cannot tell apart from a pass — so an older pin fails the job with a message
  naming the version to raise, rather than quietly gating on nothing.

### Changed

- A compliance check that does not run to a verdict is now held apart from one
  that ran and found violations. Only findings at or above the configured
  severity threshold are waivable by `block_on_violations`: that setting says the
  operator has seen those findings and accepts them, and a check that produced no
  findings has none to accept. Missing tooling, policies that could not be
  fetched and an unreadable plan all block regardless.
- A scan that does not complete is reported as an error rather than as a failure
  with zero findings — in the run log, the job summary and the pull-request
  comments.
- A check that produced no verdict now says what the scanner said, instead of
  reporting that it "did not complete" and telling the reader to re-run. Several
  of these states — a scanner that is not installed, policies that could not be
  fetched — fail identically on every attempt, so a re-run was advice that could
  not work. The pull-request comments say the same thing.

### Added

- The all-in-one pipeline action accepts `cli_version` and reports the version
  actually installed as a `cli_version` output. It previously installed the
  newest Iltero CLI on every run with no way to pin it — so a CLI release
  changed what blocks a deployment on the next run, with no opt-in, and afterwards
  there was no record of which version produced a given verdict. The two setup
  actions already accepted a version; the granular actions accept none and
  install nothing, using whatever a preceding setup step installed. Pinning
  fixes the Iltero CLI version only, not the versions of the packages it
  depends on.
- `strict_framework_scope` (`strict-framework-scope` on the granular actions),
  which fails the run when a compliance framework declared for the environment
  was not evaluated. Off by default: a shortfall can also mean Iltero has no
  policy content for that framework yet, and blocking on that would turn a gap
  on our side into an outage on yours. The shortfall is reported either way, so
  this decides whether it stops the run, not whether you are told.
- The `scan` action accepts `preview`, for scanning on pull requests without
  submitting results or writing anything back.
- The `scan` and `evaluate` actions expose a `status` output: `pass`,
  `violations`, `infra_error`, and — on `evaluate` — `needs_review`. Use it to
  tell a compliance verdict apart from a check that produced none. `passed`
  keeps its existing meaning.
- The granular `scan` and `evaluate` actions accept `config-path` and
  `frameworks`. Point `config-path` at a stack's `config.yml` and the scan or
  evaluation is checked against the compliance frameworks that file declares for
  the environment — the same behaviour as the all-in-one pipeline action. Set
  `frameworks` to a comma-separated list to bypass `config.yml`.
- The granular `evaluate` action accepts `depends-on`, a JSON array naming the
  units this unit reads Terraform state from. Note that a hand-assembled workflow
  has no record of whether those units' state is readable, so declaring
  dependencies here always plans with remote state dependencies switched off. Use
  the all-in-one pipeline action when that distinction matters.

### Fixed

- **The `scan` and `evaluate` actions could not run at all.** Both required two
  settings neither of them provided, so every invocation stopped before the
  scanner was reached. They now accept `stacks-config` and `stack-name`, which
  decide where result files are written.
- Fixing that exposed three faults these actions had never been able to reach:
  - A `config-path` pointing at a file that does not exist, or at a file that
    does not declare the environment being scanned, was treated as "no
    frameworks configured" — so a typo produced a passing scan that checked
    against nothing. Both are now errors. `config-path` no longer has a default;
    when no framework scope is in effect the run says so.
  - The `scan` action asked the Iltero CLI to rewrite the `config.yml` it had
    just read from, so a chained scan and evaluation could be scoped to
    different framework sets. It now only reads the file.
  - A `depends-on` value that was not a JSON array was read as "every
    dependency's state is available", selecting full remote-state mode against
    dependencies that were never checked. It is now an error.

- The granular `scan` and `evaluate` actions ignored the compliance frameworks a
  stack declares in `config.yml`. The same stack was therefore checked against a
  policy set depending on whether the caller used the all-in-one pipeline action
  or assembled a workflow from the granular ones. Combined with the defect above,
  the granular path produced no scan at all; both now read the same value from
  the same file.
- A `frameworks` value written as a single item instead of a list
  (`frameworks: SOC2` rather than `frameworks: [SOC2]`) silently became "no
  frameworks", and the scan reported success having checked against nothing. It
  now fails with a message naming the setting and the expected shape.
- An environment whose name contains a dot — `prod.eu` — was read as a two-level
  path and matched nothing, so the stack was skipped while the pipeline reported
  success with a deployable result. Its compliance scan types, severity threshold
  and approval requirement all fell back to defaults. Names are now looked up as
  literal keys, so such an environment is scanned with the settings it declares.
- Two further environment names were misread for the same reason: one containing
  a space was split into two names and matched nothing, and one that is not a
  plain YAML scalar (for example `&blue`) resolved to nothing, so again every
  setting fell back to its default. Both are now read as literal keys. A name
  containing `*` or `?` is rejected with a clear message instead: those
  characters are matched as patterns, so such a name answers with another
  environment's settings.
- An empty `environments:` map made the run log list one environment with a
  blank name, next to raw parser errors. It now lists none.
- A failed tool install was reported as a successful one. Every install piped its
  output through a filter and then silenced the filter, discarding the
  installer's own result: a failed Iltero CLI upgrade left whichever version was
  already present in charge of the run, and a failed Checkov install announced
  "Checkov installed" while leaving no scanner. yq, jq and OPA were additionally
  fetched without asking the download to fail on an HTTP error, so an error page
  was installed as the tool. All five installs now stop the job on failure, show
  the installer's output, and confirm the tool runs before reporting it
  installed. Affects the pipeline action and both setup actions.
- The Iltero CLI version reported by the setup actions could be the words "not
  installed" or "unknown", recorded as though they were versions while the step
  reported success. The version is now read from the installed package's own
  record rather than from the program's self-description, and a version that
  cannot be read is an error.
- A version input containing a newline was echoed into the run log, where the
  extra lines were interpreted as instructions to the runner rather than as
  text. Version inputs are now checked before use.
- Every command now invokes the Iltero CLI at the absolute path captured when it
  was installed, rather than by name. Resolving by name lets whatever appears
  first on the search path decide the outcome. All three actions that install
  the CLI now record that path, and each fails with a clear message if the
  install produced no runnable binary instead of carrying on to fail later.

  Two consequences worth knowing before upgrading:

  - **The deployment authorization check now refuses to run when no path was
    recorded.** It decides whether an apply may proceed, so a binary it cannot
    identify must not answer the question. Workflows that install the CLI
    themselves and call the deploy action without the setup action will be
    blocked; run the setup action, or set `ILTERO_CLI_BIN` to the installed
    binary.
  - **Installing the CLI now fails the job when the resolved binary sits outside
    the Python environment the action installed into.** This catches a different
    copy earlier on the search path being picked up instead. A runner image with
    its own pre-installed Iltero CLI will need that copy removed or the setup
    action's Python setup used.

### Removed

- A framework default guessed from the cloud provider named in `config.yml`. It
  read a setting that has never existed in the configuration format, so it never
  took effect. Iltero already applies a provider-appropriate default from the
  stack's own registration, which knows the real provider.

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
