# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A **configuration-driven** GitHub Actions toolkit for Terraform compliance scanning
and deployment orchestration. Reduce your infrastructure workflows from 200+ lines to ~20 lines.

## Available Actions

| Action | Description | Use Case |
|--------|-------------|----------|
| [`ilterohq/iltero-actions@v1`](#pipeline-action) | Full orchestration | **Most users** - complete compliance pipeline |
| [`ilterohq/iltero-actions/setup@v1`](#setup-action) | Install tools | Install CLI, Checkov, OPA, Terraform |
| [`ilterohq/iltero-actions/setup-oidc@v1`](#setup-oidc-action) | OIDC auth | Exchange GitHub OIDC token for Iltero API tokens |
| [`ilterohq/iltero-actions/configure-registry@v1`](#configure-registry-action) | Auth setup | Configure private module registry |
| [`ilterohq/iltero-actions/scan@v1`](#scan-action) | Static analysis | Run compliance scans |
| [`ilterohq/iltero-actions/evaluate@v1`](#evaluate-action) | Plan evaluation | Evaluate Terraform plans |
| [`ilterohq/iltero-actions/deploy@v1`](#deploy-action) | Deployment | Apply Terraform changes with Iltero tracking |
| [`ilterohq/iltero-actions/monitor@v1`](#monitor-action) | Monitoring | Drift detection and runtime compliance |

## Quick Start

### Simple Usage (Recommended)

```yaml
name: Infrastructure
on:
  push:
    branches: [main, staging, develop]
    paths: ['infra/stacks/**']

permissions:
  contents: read
  id-token: write  # Required for OIDC

jobs:
  iltero:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: ilterohq/iltero-actions@v1
        with:
          stacks_path: infra/stacks
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

> **Fallback: Token-Based Auth** — If you cannot use OIDC, set `ILTERO_TOKEN` and
> `ILTERO_REGISTRY_TOKEN` as repository secrets and pass them via `env:` instead of
> using the `oidc`, `stack_id`, and `org_id` inputs. OIDC is recommended because
> tokens are short-lived and auditable.

### Advanced Usage (Granular Control)

For power users who need custom steps between actions:

```yaml
jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v4

      # 1. Setup tools
      - uses: ilterohq/iltero-actions/setup@v1
        with:
          install-checkov: 'true'
          install-opa: 'true'

      # 2. OIDC authentication (replaces ILTERO_TOKEN secrets)
      - uses: ilterohq/iltero-actions/setup-oidc@v1
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io

      # 3. Custom validation step
      - run: ./scripts/custom-validation.sh

      # 4. Run compliance scan
      - uses: ilterohq/iltero-actions/scan@v1
        id: compliance
        with:
          path: infra/stacks/network/units/baseline
          stack-id: ${{ vars.STACK_ID }}
          unit: network-baseline
          environment: production

      # 5. Custom notification
      - if: failure()
        run: ./scripts/notify-slack.sh "Compliance failed"

      # 6. Evaluate plan (chained to compliance)
      - uses: ilterohq/iltero-actions/evaluate@v1
        with:
          path: infra/stacks/network/units/baseline
          stack-id: ${{ vars.STACK_ID }}
          unit: network-baseline
          environment: production
          run-id: ${{ steps.compliance.outputs.run-id }}
```

---

## Pipeline Action

**`ilterohq/iltero-actions@v1`** - Full orchestration for most users.

### Features

- **Automatic Stack Detection** - Detects changed stacks from git diff
- **Automatic Environment Detection** - Maps branches to environments via `git_ref.name`
- **Self-Contained** - All tools bundled within
- **Configuration-Driven** - All behavior from your `config.yml`
- **Run ID Chaining** - Links compliance → evaluation for audit trail
- **Rich Summaries** - GitHub Step Summary with detailed results

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `stacks_path` | No | `''` | Path to stacks directory (greenfield). If omitted, brownfield mode is used |
| `config_path` | No | `.iltero/config.yml` | Brownfield config file path (used when `stacks_path` is empty) |
| `environment` | No | Auto-detect | Override environment detection |
| `stack` | No | Auto-detect | Specific stack to process |
| `oidc` | No | `false` | Enable OIDC authentication (recommended) |
| `stack_id` | No | - | Iltero Stack ID (required when `oidc` is `true`) |
| `org_id` | No | - | Iltero Organization ID (required when `oidc` is `true`) |
| `registry_host` | No | `registry.iltero.io` | Private module registry |
| `dry_run` | No | `false` | Skip deployment |
| `skip_compliance` | No | `false` | Skip compliance scans |
| `deploy_only` | No | `false` | Skip compliance, deploy only (requires `run_id`) |
| `run_id` | No | - | Chain to a previous compliance run |
| `verify_authorization` | No | `true` | Verify deployment authorization via Iltero |
| `debug` | No | `false` | Enable debug output |

### Outputs

| Output | Description |
|--------|-------------|
| `overall_status` | `success`, `compliance_failed`, `evaluation_failed`, `authorization_failed`, `skipped` |
| `stacks_processed` | JSON array of processed stacks |
| `compliance_passed` | Whether compliance passed |
| `evaluation_passed` | Whether evaluation passed |
| `authorization_passed` | Whether authorization passed (deploy mode) |
| `environment` | Detected/used environment |
| `run_id` | Iltero run ID for chaining |
| `require_approval` | Whether deployment requires manual approval |
| `approval_id` | Iltero approval ID (when approval is required) |
| `deployment_ready` | Whether pipeline passed and deployment can proceed |

---

## Setup Action

**`ilterohq/iltero-actions/setup@v1`** - Install Iltero CLI and tools.

```yaml
- uses: ilterohq/iltero-actions/setup@v1
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

**`ilterohq/iltero-actions/setup-oidc@v1`** - Exchange GitHub OIDC token for short-lived Iltero API tokens.

```yaml
- uses: ilterohq/iltero-actions/setup@v1       # CLI must be installed first
- uses: ilterohq/iltero-actions/setup-oidc@v1
  with:
    stack-id: ${{ vars.ILTERO_STACK_ID }}
    org-id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

Replaces long-lived `ILTERO_TOKEN` and `ILTERO_REGISTRY_TOKEN` secrets with ephemeral
10-minute tokens. Requires a PipelinePrincipal configured in Iltero for the repository
and `permissions: { id-token: write }` on the workflow or job.

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `stack-id` | **Yes** | - | Iltero Stack ID |
| `org-id` | **Yes** | - | Iltero Organization ID |
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

**`ilterohq/iltero-actions/configure-registry@v1`** - Configure private module registry.

```yaml
- uses: ilterohq/iltero-actions/configure-registry@v1
  with:
    registry-host: registry.iltero.io  # default
  env:
    ILTERO_REGISTRY_TOKEN: ${{ secrets.ILTERO_REGISTRY_TOKEN }}
```

Configures `.netrc` and git URL rewriting for Terraform to access private modules.

---

## Scan Action

**`ilterohq/iltero-actions/scan@v1`** - Run compliance scans.

```yaml
- uses: ilterohq/iltero-actions/scan@v1
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
| `violations` | Number of violations |
| `results-file` | Path to JSON results |

---

## Evaluate Action

**`ilterohq/iltero-actions/evaluate@v1`** - Evaluate Terraform plans.

```yaml
- uses: ilterohq/iltero-actions/evaluate@v1
  with:
    path: infra/stacks/network/units/baseline
    stack-id: 0b278217-a809-465a-b9df-00eda8414cb8
    unit: network-baseline
    environment: production
    run-id: ${{ steps.scan.outputs.run-id }}  # Chain to compliance
```

---

## Deploy Action

**`ilterohq/iltero-actions/deploy@v1`** - Apply Terraform changes with Iltero tracking.

```yaml
- uses: ilterohq/iltero-actions/deploy@v1
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

- **Self-Contained Units** - Validates unit structure before deployment
- **Iltero Integration** - Notifies API of deployment start/completion
- **GitHub Deployments** - Creates GitHub Deployment status for tracking
- **State Management** - Uses environment-specific backend configuration

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | **Yes** | - | Path to self-contained unit |
| `stack-id` | **Yes** | - | Iltero stack UUID |
| `stack-name` | No | - | Human-readable stack name |
| `unit` | **Yes** | - | Infrastructure unit name |
| `environment` | **Yes** | - | Target environment |
| `run-id` | No | - | Chain to compliance/evaluation run |
| `auto-approve` | No | `false` | Skip approval for auto-apply |

### Outputs

| Output | Description |
|--------|-------------|
| `success` | Whether deployment succeeded |
| `resources-count` | Number of resources managed |
| `outputs-file` | Path to Terraform outputs JSON |

---

## Monitor Action

**`ilterohq/iltero-actions/monitor@v1`** - Drift detection and runtime compliance.

```yaml
- uses: ilterohq/iltero-actions/monitor@v1
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

- **Drift Detection** - Compares Terraform state to actual infrastructure
- **Runtime Compliance** - Scans deployed resources for violations
- **Health Checks** - Validates resource health status
- **Metrics Submission** - Reports monitoring data to Iltero
- **Issue Creation** - Optionally creates GitHub issues on drift

### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `path` | **Yes** | - | Path to self-contained unit |
| `stack-id` | **Yes** | - | Iltero stack UUID |
| `stack-name` | No | - | Human-readable stack name |
| `unit` | **Yes** | - | Infrastructure unit name |
| `environment` | **Yes** | - | Target environment |
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
| `monitoring.drift_detection.schedule` | - | Used by workflow cron trigger |
| `monitoring.alert_channels` | - | Used by backend for notifications |

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
      - uses: actions/checkout@v4

      - uses: ilterohq/iltero-actions/setup@v1

      - uses: ilterohq/iltero-actions/setup-oidc@v1
        with:
          stack-id: ${{ vars.ILTERO_STACK_ID }}
          org-id: ${{ vars.ILTERO_ORG_ID }}
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: ilterohq/iltero-actions/monitor@v1
        with:
          path: infra/stacks/my-stack/units/network
          stack-id: ${{ vars.STACK_ID }}
          stack-name: my-stack
          unit: network-baseline
          environment: production
          check-drift: 'true'
          run-compliance: 'true'
          create-issue-on-drift: 'true'
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

See [examples/monitoring.yml](examples/monitoring.yml) for a complete example with matrix strategy.

---

## Authentication

### Iltero Tokens

#### Option A: OIDC (Recommended)

OIDC exchanges a GitHub Actions token for short-lived Iltero credentials. No secrets to rotate.

**Root action** (simplest):

```yaml
- uses: ilterohq/iltero-actions@v1
  with:
    oidc: 'true'
    stack_id: ${{ vars.ILTERO_STACK_ID }}
    org_id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

**Granular actions** (setup + setup-oidc):

```yaml
- uses: ilterohq/iltero-actions/setup@v1
- uses: ilterohq/iltero-actions/setup-oidc@v1
  with:
    stack-id: ${{ vars.ILTERO_STACK_ID }}
    org-id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

Prerequisites:

- `permissions: { id-token: write }` on the workflow or job
- A PipelinePrincipal configured in Iltero for the repository
- `ILTERO_STACK_ID` and `ILTERO_ORG_ID` stored as repository **variables** (not secrets)

#### Option B: Token-Based Auth (Not Recommended)

If OIDC is not an option, use long-lived secrets:

| Secret | Purpose | Source |
|--------|---------|--------|
| `ILTERO_TOKEN` | API authentication | Dashboard -> Settings -> API Tokens |
| `ILTERO_REGISTRY_TOKEN` | Private modules | Dashboard -> Settings -> Registry Tokens |

```yaml
- uses: ilterohq/iltero-actions@v1
  with:
    stacks_path: infra/stacks
  env:
    ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}
    ILTERO_TOKEN: ${{ secrets.ILTERO_TOKEN }}
    ILTERO_REGISTRY_TOKEN: ${{ secrets.ILTERO_REGISTRY_TOKEN }}
```

### AWS Credentials

#### Option A: OIDC (Recommended)

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: ${{ vars.AWS_REGION }}
```

#### Option B: Access Keys

```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  AWS_REGION: ${{ vars.AWS_REGION }}
```

---

## Repository Structure

```text
ilterohq/iltero-actions/
├── action.yml                     # Root action (full orchestration)
├── setup/action.yml               # Install tools
├── setup-oidc/action.yml          # OIDC authentication
├── configure-registry/action.yml  # Registry auth
├── scan/action.yml                # Compliance scanning
├── evaluate/action.yml            # Plan evaluation
├── deploy/action.yml              # Terraform deployment
├── monitor/action.yml             # Drift detection & monitoring
├── actions/                       # Internal composite actions
│   ├── setup-iltero-cli/
│   ├── setup-toolchain/
│   └── parse-units/
├── scripts/                       # Pipeline scripts
├── schemas/                       # JSON Schema
└── examples/                      # Example workflows
```

---

## Self-Contained Unit Structure

**Important:** Each infrastructure unit must be **self-contained** with all required
Terraform files. This eliminates runtime file assembly and makes each unit independently
deployable.

### Required Unit Structure

```text
infra/stacks/my-stack/
├── config.yml                      # Stack configuration
└── units/
    └── network-baseline/
        ├── main.tf                 # Module calls and resources
        ├── providers.tf            # Provider configurations (with workspace tags)
        ├── versions.tf             # Terraform and provider version constraints
        ├── backend.tf              # Backend configuration (uses partial config)
        ├── data.tf                 # Data sources (optional)
        └── config/                 # Environment-specific configuration
            ├── development.tfvars
            ├── staging.tfvars
            ├── production.tfvars
            └── backend/
                ├── development.hcl
                ├── staging.hcl
                └── production.hcl
```

### File Purposes

| File | Purpose |
|------|---------|
| `main.tf` | Module calls, resources, locals |
| `providers.tf` | Provider configuration with `default_tags` including workspace/environment |
| `versions.tf` | Terraform version constraints and required providers |
| `backend.tf` | Backend configuration using `-backend-config` partial config |
| `data.tf` | Data sources for cross-unit dependencies (optional) |
| `config/{env}.tfvars` | Environment-specific variable values |
| `config/backend/{env}.hcl` | Environment-specific backend settings (bucket, key, etc.) |

### Why Self-Contained?

1. **No Runtime Assembly** - No copying files from `environments/` folders at runtime
2. **Predictable** - What you see in git is exactly what deploys
3. **IDE Support** - Full IntelliSense and validation in each unit folder
4. **Independent** - Each unit can be deployed, tested, and validated in isolation
5. **Auditable** - Clear history of all changes in one place

---

## Deployment Approvals

When your `config.yml` has `deployment.require_approval: true`, the pipeline action
will **NOT** automatically deploy. Instead, during the plan phase it:

1. Outputs `require_approval=true` and `approval_id`
2. Waits for GitHub Environment Protection approval

### How It Works

1. **Pipeline runs compliance & evaluation** - approval created automatically,
   outputs `require_approval`, `approval_id`, `run_id`
2. **Deployment job uses `environment:` keyword** - triggers GitHub approval flow
3. **Reviewers approve in GitHub UI or via CLI using `iltero stack approvals approve`**
4. **Deploy job records external approval, verifies authorization, then proceeds**

### CLI Commands for Approvals

```bash
# List pending approvals
iltero stack approvals list

# Show approval details
iltero stack approvals show <approval_id>

# Get approval for a specific run
iltero stack approvals run <run_id>

# Approve deployment (alternative to GitHub UI)
iltero stack approvals approve <approval_id> --comment "LGTM"

# Reject deployment
iltero stack approvals reject <approval_id> --reason "Needs fixes"

# View compliance analysis for a run
iltero stack approvals compliance <run_id>

# Record external approval (GitHub Environment)
iltero stack approvals record-external \
    --run-id <run_id> \
    --source github_environment \
    --approver-id <github_username> \
    --reference <workflow_url>
```

### Setup GitHub Environment Protection

1. Go to repo **Settings → Environments**
2. Create environment (e.g., `production`)
3. Enable **Required reviewers**
4. Add team members who can approve

### Example Workflow

```yaml
jobs:
  compliance:
    runs-on: ubuntu-latest
    outputs:
      environment: ${{ steps.pipeline.outputs.environment }}
      run_id: ${{ steps.pipeline.outputs.run_id }}
      require_approval: ${{ steps.pipeline.outputs.require_approval }}
      approval_id: ${{ steps.pipeline.outputs.approval_id }}
      deployment_ready: ${{ steps.pipeline.outputs.deployment_ready }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: ilterohq/iltero-actions@v1
        id: pipeline
        with:
          stacks_path: infra/stacks
          dry_run: 'true'  # Compliance only - deploy in separate job
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io

  deploy-production:
    needs: compliance
    if: |
      needs.compliance.outputs.deployment_ready == 'true' &&
      needs.compliance.outputs.environment == 'production'
    runs-on: ubuntu-latest

    # GitHub Environment Protection - pauses for approval
    environment:
      name: production
      url: https://production.example.com

    steps:
      - uses: actions/checkout@v4

      # Deploy using pipeline action with chained run_id
      - uses: ilterohq/iltero-actions@v1
        with:
          stacks_path: infra/stacks
          deploy_only: 'true'
          run_id: ${{ needs.compliance.outputs.run_id }}
          verify_authorization: 'true'
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}
        # env:
        #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

See [examples/with-approval.yml](examples/with-approval.yml) for a complete example.

---

## Stack Configuration

All behavior is controlled by your stack's `config.yml`:

```yaml
version: 1.0.0

stack:
  id: 0b278217-a809-465a-b9df-00eda8414cb8
  name: my-infrastructure
  slug: my-infrastructure

terraform:
  version: 1.5.7

infrastructure_units:
  - name: network-baseline
    path: units/network-baseline
    enabled: true
    depends_on: []
  - name: security-baseline
    path: units/security-baseline
    enabled: true
    depends_on: [network-baseline]

environments:
  development:
    git_ref:
      type: branch
      name: develop                    # develop → development
    compliance:
      enabled: true
      scan_types: [static, evaluation]
    security:
      severity_threshold: medium

  production:
    git_ref:
      type: branch
      name: main                       # main → production
    compliance:
      enabled: true
      scan_types: [static, evaluation]
    security:
      severity_threshold: high
    deployment:
      require_approval: true
```

### Brownfield (Attached) Stacks

For existing Terraform projects, use an "attached" stack config at `.iltero/config.yml`:

```yaml
stack:
  id: a1b2c3d4-e5f6-7890-abcd-ef1234567890
  name: my-existing-project
  type: attached                       # Required for brownfield
  terraform_working_directory: terraform  # Path to existing TF root

environments:
  production:
    git_ref: { type: branch, name: main }
    compliance:
      enforcement_mode: permissive     # Report violations without blocking
      policy_sets: [aws-security-baseline]
```

No `infrastructure_units` section is needed.
See [examples/config.brownfield.example.yml](examples/config.brownfield.example.yml)
for a complete reference.

---

## Examples

See [examples/](examples/) for complete workflow examples:

- **basic.yml** - Minimal workflow with OIDC
- **multi-environment.yml** - Branch-based environments
- **manual-trigger.yml** - workflow_dispatch with inputs
- **complete.yml** - All features (PR comments, Slack notifications)
- **with-approval.yml** - Deployment with GitHub environment protection
- **oidc.yml** - OIDC authentication patterns (root action and granular)
- **brownfield.yml** - Existing Terraform project with Iltero compliance
- **monitoring.yml** - Scheduled drift detection and runtime compliance
- **security-hardened.yml** - Security best practices (SHA-pinned actions, input validation)
- **config.example.yml** - Greenfield stack configuration reference
- **config.brownfield.example.yml** - Brownfield stack configuration reference

---

## Contributing

Contributions welcome! Please read our [Contributing Guide](CONTRIBUTING.md).

## License

Apache License 2.0 - see [LICENSE](LICENSE) for details.

---

Made with ❤️ by [Iltero](https://iltero.io)
