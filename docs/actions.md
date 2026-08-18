# Actions Reference

Complete reference for every action in this toolkit. For an overview and quick start, see the [README](../README.md).

**Replace `RELEASE_COMMIT_SHA`** in every example below with the commit SHA of
the release you want to pin to — it is shown on that release's page under
[Releases](https://github.com/ilterohq/iltero-actions/releases). The placeholder
is deliberate: a version written into an example is a value people copy long
after it has gone stale.

## Table of Contents

- [Pipeline Action](#pipeline-action) — Full orchestration (most users)
- [Setup Action](#setup-action) — Install CLI and tools
- [Setup OIDC Action](#setup-oidc-action) — Exchange GitHub OIDC for Iltero tokens
- [Configure Registry Action](#configure-registry-action) — Private module registry auth
- [Scan Action](#scan-action) — Static analysis
- [Evaluate Action](#evaluate-action) — Plan evaluation
- [Deploy Action](#deploy-action) — Apply IaC changes with Iltero tracking
- [Monitor Action](#monitor-action) — Drift detection and runtime compliance
- [Granular Usage Example](#granular-usage-example) — Custom pipelines with individual actions

---

## Pipeline Action

**`ilterohq/iltero-actions`** — Full orchestration for most users.

### Features

- **Automatic Stack Detection** — Detects changed stacks from git diff
- **Automatic Environment Detection** — Maps branches to environments via `git_ref.name` in `config.yml`
- **Self-Contained** — All tools bundled within
- **Configuration-Driven** — All behavior from your `config.yml`
- **Run ID Chaining** — Links static analysis → plan evaluation → deploy for audit trail
- **Rich Summaries** — GitHub Step Summary with detailed results

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `stacks_path` | No | `''` | Path to stacks directory (greenfield). If omitted, brownfield mode is used |
| `config_path` | No | `.iltero/config.yml` | Brownfield config file path (used when `stacks_path` is empty) |
| `environment` | No | Auto-detect | Override environment detection |
| `stack` | No | Auto-detect | Specific stack to process |
| `oidc` | No | `false` | Enable OIDC authentication (recommended) |
| `org_id` | No | — | Iltero Organization ID (required when `oidc` is `true`) |
| `registry_host` | No | `registry.iltero.io` | Private module registry |
| `comment_on_pr` | No | `true` | Post an advisory result comment on `pull_request` runs (needs `pull-requests: write`). Set `false` if you post your own comment from a separate job |
| `mode` | No | `full` | Pipeline mode: `full`, `preview`, `scan`, `evaluate`, `scan_evaluate`, `deploy` |
| `run_id` | No | — | Chain to a previous compliance run (required when `mode` is `deploy`) |
| `verify_authorization` | No | `true` | Verify deployment authorization via Iltero |
| `terraform_version` | No | newest 1.10.x | Terraform version to install (exact, `latest`, or a constraint). `terraform.version` in `config.yml` is not used for installation |
| `cli_version` | No | `0.7.1` | Iltero CLI version to install. Pinned by default so a CLI release cannot change what blocks a deployment without an explicit change. Must be `0.7.0` or newer |
| `strict_framework_scope` | No | `false` | Fail the run when a compliance framework declared for the environment was not evaluated. The shortfall is reported either way; this decides whether it stops the run |
| `debug` | No | `false` | Enable debug output |

### Outputs

| Output | Description |
|--------|-------------|
| `overall_status` | `success`, `static_scan_failed`, `evaluation_failed`, `authorization_failed`, `skipped` |
| `stacks_processed` | JSON array of processed stacks |
| `static_scan_passed` | Whether static analysis passed |
| `evaluation_passed` | Whether plan evaluation passed |
| `compliance_only` | `true` when mode is `preview`, `scan`, `evaluate`, or `scan_evaluate`, and for PR events |
| `authorization_passed` | Whether authorization passed (deploy mode) |
| `environment` | Detected/used environment |
| `run_id` | Iltero run ID for chaining |
| `require_approval` | Whether deployment requires manual approval |
| `approval_id` | Iltero approval ID (when approval is required) |
| `deployment_ready` | Whether pipeline passed and deployment can proceed |
| `terraform_version` | The Terraform version that was installed and used |
| `cli_version` | The Iltero CLI version that was installed and used |

---

## Setup Action

**`ilterohq/iltero-actions/setup`** — Install Iltero CLI and tools.

```yaml
- uses: ilterohq/iltero-actions/setup@RELEASE_COMMIT_SHA # v0.2.0
  with:
    install-checkov: 'true'
    install-opa: 'true'
    install-toolchain: 'true'  # Terraform, yq, jq
```

### Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `version` | `latest` | Iltero CLI version |
| `python-version` | `3.11` | Python version |
| `install-checkov` | `true` | Install Checkov |
| `install-opa` | `true` | Install OPA |
| `opa-version` | `0.60.0` | OPA version |
| `install-toolchain` | `true` | Install Terraform, yq, jq |
| `terraform-version` | `1.5.7` | Terraform version |

---

## Setup OIDC Action

**`ilterohq/iltero-actions/setup-oidc`** — Exchange GitHub OIDC token for short-lived Iltero API tokens.

```yaml
- uses: ilterohq/iltero-actions/setup@RELEASE_COMMIT_SHA # v0.2.0       # CLI must be installed first
- uses: ilterohq/iltero-actions/setup-oidc@RELEASE_COMMIT_SHA # v0.2.0
  with:
    stack-id: ${{ vars.ILTERO_STACK_ID }}
    org-id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

Replaces long-lived `ILTERO_TOKEN` and `ILTERO_REGISTRY_TOKEN` secrets with
ephemeral 10-minute tokens. Requires a pipeline principal configured in Iltero
for the repository and `permissions: { id-token: write }` on the workflow or job.

See [Authentication](authentication.md) for full setup details.

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `stack-id` | **Yes** | — | Iltero Stack ID |
| `org-id` | **Yes** | — | Iltero Organization ID |
| `api-url` | No | `https://api.iltero.io` | Iltero API URL (or `ILTERO_API_URL` env) |
| `registry-host` | No | `registry.iltero.io` | Registry hostname |
| `configure-registry` | No | `true` | Auto-configure Terraform registry credentials |

### Outputs

| Output | Description |
|--------|-------------|
| `api-token` | Short-lived Iltero API token (also exported as `ILTERO_TOKEN`) |
| `registry-token` | Short-lived registry token (also exported as `ILTERO_REGISTRY_TOKEN`) |
| `expires-at` | Token expiration timestamp (ISO 8601) |

---

## Configure Registry Action

**`ilterohq/iltero-actions/configure-registry`** — Configure private module registry.

```yaml
- uses: ilterohq/iltero-actions/configure-registry@RELEASE_COMMIT_SHA # v0.2.0
  with:
    registry-host: registry.iltero.io  # default
  env:
    ILTERO_REGISTRY_TOKEN: ${{ secrets.ILTERO_REGISTRY_TOKEN }}
```

Configures `.netrc` and git URL rewriting so Terraform can access private modules.

---

## Scan Action

**`ilterohq/iltero-actions/scan`** — Run static analysis (Checkov via Iltero CLI).

```yaml
- uses: ilterohq/iltero-actions/scan@RELEASE_COMMIT_SHA # v0.2.0
  with:
    path: infra/stacks/my-stack/units/network
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    stack-name: my-stack
    unit: network
    environment: production
    fail-on: high
    # config.yml belongs to the stack, not to a unit.
    config-path: .iltero/stacks/my-stack/config.yml
```

### Compliance frameworks

A stack names the compliance frameworks it must be checked against, per
environment, in its `config.yml`:

```yaml
environments:
  production:
    compliance:
      frameworks: [SOC2, ISO27001, CIS-AWS]
```

Point `config-path` at that file and the scan is checked against exactly those
frameworks — the same behaviour as the all-in-one pipeline action. The file is
only read; the scan action never writes to it.

`config-path` has no default: leave it unset and no framework list is read. When
you do set it, the file must exist and must declare the environment being
scanned, or the run stops. A path that pointed nowhere would otherwise scan
against no frameworks and report success.

To bypass `config.yml`, set `frameworks` directly to a comma-separated list
(`SOC2,ISO27001`). When neither is set, no framework list is sent and Iltero
decides which policies apply from the stack's own registration — which the run
log states explicitly, so a missing scope is never silent.

Both actions also accept `stacks-config` and `stack-name`, which decide where
result files are written (`<stacks-config>/<stack-name>/`). Use the same values
across the actions in a workflow so a later step finds the earlier step's
results. `stack-name` defaults to the stack UUID.

A `frameworks` value written as a single item instead of a list
(`frameworks: SOC2` rather than `frameworks: [SOC2]`) fails the run. It is not
treated as "no frameworks", because that would report a passing scan that had
checked nothing.

### Outputs

| Output | Description |
|--------|-------------|
| `passed` | Whether scan passed |
| `status` | `pass`, `violations`, or `infra_error` — see below |
| `run-id` | Iltero run ID for chaining |
| `violations` | Number of findings above threshold |
| `results-file` | Path to JSON results |

`status` distinguishes a compliance verdict from a scan that did not produce
one. `violations` means the scan ran and found findings at or above the
threshold — a result you may choose to accept. `infra_error` means no verdict
exists: the scan did not complete, so there is nothing to accept. Gate on
`status` rather than `passed` when that difference matters.

---

## Evaluate Action

**`ilterohq/iltero-actions/evaluate`** — Evaluate IaC plans against OPA policies.

```yaml
- uses: ilterohq/iltero-actions/evaluate@RELEASE_COMMIT_SHA # v0.2.0
  with:
    path: infra/stacks/my-stack/units/app
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    stack-name: my-stack
    unit: app
    environment: production
    run-id: ${{ steps.scan.outputs.run-id }}  # Chain to static analysis
    config-path: .iltero/stacks/my-stack/config.yml
    depends-on: '["network"]'                  # Units this one reads state from
```

`config-path` and `frameworks` work exactly as described under
[Scan Action](#compliance-frameworks).

`depends-on` lists the units this unit reads Terraform state from. Terraform
needs that state to be readable to produce a plan; when one of those units'
state is not available, the plan is re-run with remote state dependencies
switched off so the evaluation still produces a result instead of failing. Leave
it out when the unit has no upstream units.

### Outputs

| Output | Description |
|--------|-------------|
| `passed` | Whether evaluation passed |
| `status` | `pass`, `violations`, `needs_review`, or `infra_error` — see below |
| `run-id` | Iltero run ID for chaining |
| `violations` | Number of policy violations found |
| `plan-file` | Path to the generated plan JSON |

`status` carries the same meaning as on the scan action, with one extra value:
`needs_review` means the evaluation ran but nothing could be confirmed — for
example a plan whose checks cannot be resolved until apply. It is not a pass and
is never waivable.

---

## Deploy Action

**`ilterohq/iltero-actions/deploy`** — Apply IaC changes with Iltero tracking.

```yaml
- uses: ilterohq/iltero-actions/deploy@RELEASE_COMMIT_SHA # v0.2.0
  with:
    path: infra/stacks/network/units/baseline
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    stack-name: network-infrastructure
    unit: network-baseline
    environment: production
    run-id: ${{ steps.evaluate.outputs.run-id }}
    auto-approve: 'true'
```

### Features

- **Self-Contained Units** — Validates unit structure before deployment
- **Iltero Integration** — Notifies API of deployment start/completion
- **GitHub Deployments** — Creates GitHub Deployment status for tracking
- **State Management** — Uses environment-specific backend configuration

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | **Yes** | — | Path to self-contained unit |
| `stack-id` | **Yes** | — | Iltero stack UUID |
| `stack-name` | No | — | Human-readable stack name |
| `unit` | **Yes** | — | Infrastructure unit name |
| `environment` | **Yes** | — | Target environment |
| `run-id` | No | — | Chain to compliance/evaluation run |
| `auto-approve` | No | `false` | Skip approval for auto-apply |

### Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether deployment succeeded |
| `resources-count` | Number of resources managed |
| `outputs-file` | Path to Terraform outputs JSON |

---

## Monitor Action

**`ilterohq/iltero-actions/monitor`** — Drift detection and runtime compliance.

```yaml
- uses: ilterohq/iltero-actions/monitor@RELEASE_COMMIT_SHA # v0.2.0
  with:
    path: infra/stacks/network/units/baseline
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    stack-name: network-infrastructure
    unit: network-baseline
    environment: production
    check-drift: 'true'
    run-compliance: 'true'
    check-health: 'true'
```

### Features

- **Drift Detection** — Compares Terraform state to actual infrastructure
- **Runtime Compliance** — Scans deployed resources for violations
- **Health Checks** — Validates resource health status
- **Metrics Submission** — Reports monitoring data to Iltero
- **Issue Creation** — Optionally creates GitHub issues on drift

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | **Yes** | — | Path to self-contained unit |
| `stack-id` | **Yes** | — | Iltero stack UUID |
| `stack-name` | No | — | Human-readable stack name |
| `unit` | **Yes** | — | Infrastructure unit name |
| `environment` | **Yes** | — | Target environment |
| `check-drift` | No | `true` | Enable drift detection |
| `run-compliance` | No | `true` | Run runtime compliance scan |
| `check-health` | No | `true` | Check resource health |
| `create-issues-on-drift` | No | `false` | Create GitHub issues on drift |

### Outputs

| Output | Description |
|--------|-------------|
| `drift-detected` | Whether drift was detected |
| `resources-count` | Number of resources monitored |
| `compliance-passed` | Whether runtime compliance passed |
| `health-status` | Overall health status |

### Monitoring Configuration

Configure monitoring behavior in your stack's `config.yml`:

```yaml
environments:
  production:
    monitoring:
      enabled: true                    # Enable monitoring for this environment
      alert_channels: [slack, email]   # Notification channels
      log_retention_days: 90           # Logs retention period
      drift_detection:
        enabled: true                  # Enable drift detection
        schedule: 0 */4 * * *          # Cron: every 4 hours
        auto_remediate: false          # Manual remediation
      compliance_monitoring:
        real_time: false               # Scheduled checks
        alert_on_violations: true      # Alert on violations
```

**Mapping to Action Inputs:**

| Config Field | Action Input | Description |
|--------------|--------------|-------------|
| `monitoring.drift_detection.enabled` | `check-drift` | Controls drift detection |
| `monitoring.compliance_monitoring` | `run-compliance` | Controls runtime compliance scan |
| `monitoring.drift_detection.schedule` | — | Used by workflow cron trigger |
| `monitoring.alert_channels` | — | Used by backend for notifications |

**Example Scheduled Workflow:**

```yaml
name: Infrastructure Monitoring
on:
  schedule:
    - cron: '0 */4 * * *'  # Every 4 hours (from config.yml)
  workflow_dispatch:

permissions:
  contents: read
  id-token: write
  issues: write

jobs:
  monitor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - uses: ilterohq/iltero-actions/setup@RELEASE_COMMIT_SHA # v0.2.0

      - uses: ilterohq/iltero-actions/setup-oidc@RELEASE_COMMIT_SHA # v0.2.0
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}

      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: ilterohq/iltero-actions/monitor@RELEASE_COMMIT_SHA # v0.2.0
        with:
          path: infra/stacks/my-stack/units/network
          stack-id: ${{ vars.STACK_ID }}
          stack-name: my-stack
          unit: network-baseline
          environment: production
          check-drift: 'true'
          run-compliance: 'true'
          create-issue-on-drift: 'true'
```

See [examples/monitoring.yml](../examples/monitoring.yml) for a complete example with matrix strategy.

---

## Granular Usage Example

For custom pipelines that need steps between actions:

```yaml
jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      # 1. Install tools
      - uses: ilterohq/iltero-actions/setup@RELEASE_COMMIT_SHA # v0.2.0
        with:
          install-checkov: 'true'
          install-opa: 'true'

      # 2. OIDC authentication (replaces ILTERO_TOKEN secrets)
      - uses: ilterohq/iltero-actions/setup-oidc@RELEASE_COMMIT_SHA # v0.2.0
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}

      # 3. Custom validation step
      - run: ./scripts/custom-validation.sh

      # 4. Run static analysis
      - uses: ilterohq/iltero-actions/scan@RELEASE_COMMIT_SHA # v0.2.0
        id: compliance
        with:
          path: infra/stacks/my-stack/units/network
          stack-id: ${{ vars.STACK_ID }}
          stack-name: my-stack
          unit: network
          environment: production
          config-path: .iltero/stacks/my-stack/config.yml

      # 5. Custom notification on failure
      - if: failure()
        run: ./scripts/notify-slack.sh "Compliance failed"

      # 6. Evaluate plan (chained to scan)
      - uses: ilterohq/iltero-actions/evaluate@RELEASE_COMMIT_SHA # v0.2.0
        with:
          path: infra/stacks/my-stack/units/network
          stack-id: ${{ vars.STACK_ID }}
          stack-name: my-stack
          unit: network
          environment: production
          run-id: ${{ steps.compliance.outputs.run-id }}
          config-path: .iltero/stacks/my-stack/config.yml
```
