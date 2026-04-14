# Deployment Approvals

When a stack's `config.yml` has `deployment.require_approval: true`, Iltero Actions will run compliance and evaluation but **will not deploy automatically**. Deployment waits for a human to approve via GitHub Environment Protection or the Iltero CLI.

## Table of Contents

- [How It Works](#how-it-works)
- [Setup: GitHub Environment Protection](#setup-github-environment-protection)
- [Example Workflow](#example-workflow)
- [CLI Commands](#cli-commands)
- [Troubleshooting](#troubleshooting)

---

## How It Works

1. **Pipeline runs compliance and evaluation** on push. If they pass and the environment requires approval, the pipeline creates an approval record and outputs:
   - `require_approval=true`
   - `approval_id=<uuid>`
   - `run_id=<uuid>`
   - `deployment_ready=true`

2. **A downstream deploy job declares `environment: <name>`**, which triggers GitHub Environment Protection. The job pauses and shows in the Actions UI as waiting for approval.

3. **Reviewers approve** — either in the GitHub UI (Actions → the run → "Review deployments") or via `iltero stack approvals approve <approval_id>`.

4. **The deploy job resumes**, records the external approval with Iltero, calls `verify_authorization`, and then runs `terraform apply`.

Approval is tracked at two layers:

- **GitHub** — the Environment Protection gate blocks the job until a human approves
- **Iltero** — the backend records who approved, when, and links it to the scan/evaluation run IDs for the audit trail

---

## Setup: GitHub Environment Protection

1. Go to your repo **Settings → Environments**
2. Click **New environment** and name it (e.g., `production`) — the name must match the `environment:` key in your deploy job
3. Under **Deployment protection rules**, enable **Required reviewers**
4. Add the team members or teams authorized to approve deployments
5. (Optional) Configure **Deployment branches** to limit which branches can deploy — e.g., `main` only for production
6. (Optional) Set a **Wait timer** to force a cooling-off period before deployment runs

See [GitHub's docs on environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) for more.

---

## Example Workflow

Two-job pattern: one job runs compliance, a second job waits for approval and deploys.

```yaml
jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      environment: ${{ steps.pipeline.outputs.environment }}
      run_id: ${{ steps.pipeline.outputs.run_id }}
      require_approval: ${{ steps.pipeline.outputs.require_approval }}
      approval_id: ${{ steps.pipeline.outputs.approval_id }}
      deployment_ready: ${{ steps.pipeline.outputs.deployment_ready }}
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - uses: ilterohq/iltero-actions@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        id: pipeline
        with:
          stacks_path: infra/stacks
          dry_run: 'true'                        # Compliance only — deploy in separate job
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}

  deploy-production:
    needs: compliance
    if: |
      needs.compliance.outputs.deployment_ready == 'true' &&
      needs.compliance.outputs.environment == 'production' &&
      github.event_name == 'push'                # Never deploy from PRs
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      deployments: write

    # GitHub Environment Protection — pauses for approval
    environment:
      name: production
      url: https://production.example.com

    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN_PROD }}
          aws-region: ${{ vars.AWS_REGION }}

      # Deploy using the pipeline action with chained run_id
      - uses: ilterohq/iltero-actions@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
        with:
          stacks_path: infra/stacks
          deploy_only: 'true'
          run_id: ${{ needs.compliance.outputs.run_id }}
          verify_authorization: 'true'
          oidc: 'true'
          stack_id: ${{ vars.ILTERO_STACK_ID }}
          org_id: ${{ vars.ILTERO_ORG_ID }}
```

See [`examples/with-approval.yml`](../examples/with-approval.yml) for a complete multi-environment example (dev and staging auto-deploy, production requires approval).

---

## CLI Commands

For teams that prefer approving from the terminal:

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

# Record external approval (when approval happened outside Iltero, e.g., in the GitHub UI)
iltero stack approvals record-external \
    --run-id <run_id> \
    --source github_environment \
    --approver-id <github_username> \
    --reference <workflow_url>
```

---

## Troubleshooting

**Job is stuck in "waiting for approval" but nobody is listed as a reviewer**

Check Settings → Environments → your environment → Deployment protection rules. Make sure "Required reviewers" is enabled and at least one user or team is listed.

**Deploy job fails with "authorization_failed"**

The `verify_authorization` step checks with Iltero that the deployment is authorized. Common causes:

- The `run_id` passed to deploy doesn't match the one from compliance (check the `needs.compliance.outputs.run_id` wiring)
- Compliance or evaluation actually failed (check `deployment_ready` is `true` before deploying)
- The GitHub user who approved doesn't have permission in Iltero (add them as an approver in the Iltero dashboard)

**Approval happens but the deploy job doesn't resume**

GitHub Environment approval is separate from the Iltero approval record. Make sure the deploy job references the right environment name — it must match the name you configured in Settings → Environments exactly.

---

## Further reading

- [GitHub: Using environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [Actions Reference: Pipeline action outputs](actions.md#pipeline-action) — for `require_approval`, `approval_id`, `deployment_ready`
- [Configuration: `require_approval`](configuration.md#stack-configuration) — how to enable per-environment
