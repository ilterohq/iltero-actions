# Actions Reference

Complete reference for every action in this toolkit. For an overview and quick start, see the [README](../README.md).

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

**`ilterohq/iltero-actions@v1`** — Full orchestration for most users.

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
| `dry_run` | No | `false` | Skip deployment |
| `skip_compliance` | No | `false` | Skip compliance scans |
| `deploy_only` | No | `false` | Skip compliance, deploy only (requires `run_id`) |
| `run_id` | No | — | Chain to a previous compliance run |
| `verify_authorization` | No | `true` | Verify deployment authorization via Iltero |
| `debug` | No | `false` | Enable debug output |

### Outputs

| Output | Description |
|--------|-------------|
| `overall_status` | `success`, `static_scan_failed`, `evaluation_failed`, `authorization_failed`, `skipped` |
| `stacks_processed` | JSON array of processed stacks |
| `static_scan_passed` | Whether static analysis passed |
| `evaluation_passed` | Whether plan evaluation passed |
| `compliance_only` | `true` when running on a pull request (no deployment) |
| `authorization_passed` | Whether authorization passed (deploy mode) |
| `environment` | Detected/used environment |
| `run_id` | Iltero run ID for chaining |
| `require_approval` | Whether deployment requires manual approval |
| `approval_id` | Iltero approval ID (when approval is required) |
| `deployment_ready` | Whether pipeline passed and deployment can proceed |

---

## Setup Action

**`ilterohq/iltero-actions/setup@v1`** — Install Iltero CLI and tools.

```yaml
- uses: ilterohq/iltero-actions/setup@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
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

**`ilterohq/iltero-actions/setup-oidc@v1`** — Exchange GitHub OIDC token for short-lived Iltero API tokens.

```yaml
- uses: ilterohq/iltero-actions/setup@41bada1ab6681a6de40b2584a109a177f7345d06 # v1       # CLI must be installed first
- uses: ilterohq/iltero-actions/setup-oidc@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    stack-id: ${{ vars.ILTERO_STACK_ID }}
    org-id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

Replaces long-lived `ILTERO_TOKEN` and `ILTERO_REGISTRY_TOKEN` secrets with ephemeral 10-minute tokens. Requires a PipelinePrincipal configured in Iltero for the repository and `permissions: { id-token: write }` on the workflow or job.

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

**`ilterohq/iltero-actions/configure-registry@v1`** — Configure private module registry.

```yaml
- uses: ilterohq/iltero-actions/configure-registry@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    registry-host: registry.iltero.io  # default
  env:
    ILTERO_REGISTRY_TOKEN: ${{ secrets.ILTERO_REGISTRY_TOKEN }}
```

Configures `.netrc` and git URL rewriting so Terraform can access private modules.

---

## Scan Action

**`ilterohq/iltero-actions/scan@v1`** — Run static analysis (Checkov via Iltero CLI).

```yaml
- uses: ilterohq/iltero-actions/scan@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    path: infra/stacks/network/units/baseline
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    unit: network-baseline
    environment: production
    fail-on: high
```

### Outputs

| Output | Description |
|--------|-------------|
| `passed` | Whether scan passed |
| `run-id` | Iltero run ID for chaining |
| `violations` | Number of findings above threshold |
| `results-file` | Path to JSON results |

---

## Evaluate Action

**`ilterohq/iltero-actions/evaluate@v1`** — Evaluate IaC plans against OPA policies.

```yaml
- uses: ilterohq/iltero-actions/evaluate@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    path: infra/stacks/network/units/baseline
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    unit: network-baseline
    environment: production
    run-id: ${{ steps.scan.outputs.run-id }}  # Chain to static analysis
```

---

## Deploy Action

**`ilterohq/iltero-actions/deploy@v1`** — Apply IaC changes with Iltero tracking.

```yaml
- uses: ilterohq/iltero-actions/deploy@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
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

**`ilterohq/iltero-actions/monitor@v1`** — Drift detection and runtime compliance.

```yaml
- uses: ilterohq/iltero-actions/monitor@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
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

      - uses: ilterohq/iltero-actions/setup@41bada1ab6681a6de40b2584a109a177f7345d06 # v1

      - uses: ilterohq/iltero-actions/setup-oidc@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}

      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: ilterohq/iltero-actions/monitor@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
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
      - uses: ilterohq/iltero-actions/setup@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          install-checkov: 'true'
          install-opa: 'true'

      # 2. OIDC authentication (replaces ILTERO_TOKEN secrets)
      - uses: ilterohq/iltero-actions/setup-oidc@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}

      # 3. Custom validation step
      - run: ./scripts/custom-validation.sh

      # 4. Run static analysis
      - uses: ilterohq/iltero-actions/scan@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        id: compliance
        with:
          path: infra/stacks/network/units/baseline
          stack-id: ${{ vars.STACK_ID }}
          unit: network-baseline
          environment: production

      # 5. Custom notification on failure
      - if: failure()
        run: ./scripts/notify-slack.sh "Compliance failed"

      # 6. Evaluate plan (chained to scan)
      - uses: ilterohq/iltero-actions/evaluate@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          path: infra/stacks/network/units/baseline
          stack-id: ${{ vars.STACK_ID }}
          unit: network-baseline
          environment: production
          run-id: ${{ steps.compliance.outputs.run-id }}
```
