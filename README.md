# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A **configuration-driven** GitHub Actions toolkit for Infrastructure as Code (IaC)
compliance scanning and deployment orchestration. Reduce your infrastructure workflows
from 200+ lines to ~20.

> **Supported IaC tools:** Terraform today. OpenTofu, Pulumi, and CloudFormation are
> on the roadmap — the pipeline, policy engine, and audit trail are IaC-agnostic.

## What you get

- **Static analysis** of your IaC configurations via Checkov, before the plan runs
- **Plan evaluation** against OPA policies, with the full plan JSON submitted to Iltero for audit
- **Automatic environment detection** — branches map to environments via `git_ref` in `config.yml`
- **Automatic stack detection** — changed stacks are picked up from `git diff`
- **Deployment approvals** via GitHub Environment Protection with Iltero audit trail
- **Run ID chaining** — scan → evaluate → deploy linked end-to-end for compliance reporting

## Quick start

```yaml
name: Infrastructure
on:
  push:
    branches: [main, staging, develop]
    paths: ['infra/stacks/**']
  pull_request:
    paths: ['infra/stacks/**']

permissions:
  contents: read
  id-token: write  # Required for OIDC

jobs:
  iltero:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - uses: ilterohq/iltero-actions@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          stacks_path: infra/stacks
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}
```

> **Not using OIDC?** Set `ILTERO_TOKEN` and `ILTERO_REGISTRY_TOKEN` as repository
> secrets and pass them via `env:` instead of `oidc`/`stack_id`/`org_id`.
> OIDC is strongly recommended — see [docs/authentication.md](docs/authentication.md).

## Documentation

| Topic | What's inside |
|-------|---------------|
| [Actions Reference](docs/actions.md) | Every action, inputs, outputs, granular usage patterns |
| [Authentication](docs/authentication.md) | Iltero OIDC/tokens, AWS OIDC/access keys, trust policy setup |
| [Configuration](docs/configuration.md) | `config.yml` schema, self-contained units, brownfield stacks |
| [Security](docs/security.md) | SHA pinning, Dependabot, zizmor, permissions, fork PRs |
| [Approvals](docs/approvals.md) | GitHub Environment Protection + Iltero approval workflow |

## Available actions

| Action | Use case |
|--------|----------|
| [`ilterohq/iltero-actions@v1`](docs/actions.md#pipeline-action) | Full orchestration — most users |
| [`ilterohq/iltero-actions/setup@v1`](docs/actions.md#setup-action) | Install CLI, Checkov, OPA, Terraform |
| [`ilterohq/iltero-actions/setup-oidc@v1`](docs/actions.md#setup-oidc-action) | Exchange GitHub OIDC for Iltero tokens |
| [`ilterohq/iltero-actions/configure-registry@v1`](docs/actions.md#configure-registry-action) | Private module registry auth |
| [`ilterohq/iltero-actions/scan@v1`](docs/actions.md#scan-action) | Static analysis |
| [`ilterohq/iltero-actions/evaluate@v1`](docs/actions.md#evaluate-action) | Plan evaluation |
| [`ilterohq/iltero-actions/deploy@v1`](docs/actions.md#deploy-action) | Apply IaC changes with Iltero tracking |
| [`ilterohq/iltero-actions/monitor@v1`](docs/actions.md#monitor-action) | Drift detection and runtime compliance |

## Examples

Complete workflow examples live in [`examples/`](examples/):

| File | Use case |
|------|----------|
| [`basic.yml`](examples/basic.yml) | Minimal workflow with OIDC |
| [`multi-environment.yml`](examples/multi-environment.yml) | Branch-based environments |
| [`manual-trigger.yml`](examples/manual-trigger.yml) | `workflow_dispatch` with input validation |
| [`complete.yml`](examples/complete.yml) | All features (PR comments, Slack notifications) |
| [`with-approval.yml`](examples/with-approval.yml) | Deployment approval via GitHub Environments |
| [`oidc.yml`](examples/oidc.yml) | OIDC authentication (root action and granular) |
| [`brownfield.yml`](examples/brownfield.yml) | Existing Terraform project with Iltero compliance |
| [`monitoring.yml`](examples/monitoring.yml) | Scheduled drift detection |
| [`security-hardened.yml`](examples/security-hardened.yml) | SHA-pinned actions, input validation, least-privilege |
| [`workflow-security.yml`](examples/workflow-security.yml) | zizmor static analysis for your workflows |
| [`config.example.yml`](examples/config.example.yml) | Greenfield stack configuration reference |
| [`config.brownfield.example.yml`](examples/config.brownfield.example.yml) | Brownfield stack configuration reference |

## Contributing

Contributions welcome — please read the [Contributing Guide](CONTRIBUTING.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.
