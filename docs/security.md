# Security

This page covers supply-chain and workflow-security practices for Iltero Actions users. If you're setting up auth, see [Authentication](authentication.md). If you're setting up deployment approvals, see [Approvals](approvals.md).

## Table of Contents

- [Pinning Actions](#pinning-actions)
  - [Recommended (SHA-pinned)](#recommended-sha-pinned)
  - [Not recommended (tag-pinned)](#not-recommended-tag-pinned)
  - [Finding the SHA for an action](#finding-the-sha-for-an-action)
  - [Keeping pinned SHAs fresh with Dependabot](#keeping-pinned-shas-fresh-with-dependabot)
  - [Automated verification with zizmor](#automated-verification-with-zizmor)
- [Secrets and Variables](#secrets-and-variables)
- [Workflow Permissions](#workflow-permissions)
- [Public Repositories and Fork PRs](#public-repositories-and-fork-prs)
- [Further reading](#further-reading)

---

## Pinning Actions

**For production workflows, pin every third-party action to a full commit SHA, not a tag.** Tags are mutable — an attacker who compromises an action repository can force-push a malicious commit to an existing tag, and your next workflow run will silently execute it with access to your secrets.

### Recommended (SHA-pinned)

```yaml
steps:
  - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
  - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
  - uses: ilterohq/iltero-actions@REPLACE_WITH_SHA # v1
```

Include the version comment (`# v6.0.2`) so reviewers can read intent without decoding the SHA, and so Dependabot can parse and update it.

### Not recommended (tag-pinned)

```yaml
steps:
  - uses: actions/checkout@v4                          # tag can be moved
  - uses: aws-actions/configure-aws-credentials@v4     # tag can be moved
  - uses: ilterohq/iltero-actions@v1                   # tag can be moved
```

### Finding the SHA for an action

```bash
# Get the SHA for a tag using the GitHub CLI
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'

# Or visit the action's releases page and copy the commit SHA:
# https://github.com/actions/checkout/releases
```

### Keeping pinned SHAs fresh with Dependabot

SHA pinning does **not** prevent updates. Dependabot reads the version comment and opens PRs that update both the SHA and the comment together. Add to `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

Review each Dependabot PR in the Security tab or via PR review — the changelog lives in the commit message Dependabot generates.

### Automated verification with zizmor

[zizmor](https://github.com/zizmorcore/zizmor) is a static analyzer for GitHub Actions workflows. It catches:

- Unpinned actions (this page's main topic)
- Template injection in `run:` blocks (e.g., unquoted `${{ inputs.* }}`)
- Over-privileged `GITHUB_TOKEN` permissions
- `pull_request_target` misuse against untrusted code
- Cache poisoning patterns

See [`examples/workflow-security.yml`](../examples/workflow-security.yml) for a drop-in CI workflow that runs zizmor on every push and PR, and uploads findings to the Security tab as SARIF.

---

## Secrets and Variables

Use the right store for each kind of value:

| Store | What goes here | Examples |
|-------|----------------|----------|
| **Secrets** | Credentials, tokens, API keys | `ILTERO_TOKEN`, `AWS_ROLE_ARN`, `GITHUB_TOKEN` |
| **Variables** | Non-sensitive config | `ILTERO_STACK_ID`, `ILTERO_ORG_ID`, `AWS_REGION`, `ILTERO_API_URL` |

GitHub masks secret values in logs automatically. Variables are visible in logs — don't put anything sensitive there.

**Scope:**

- **Organization** secrets/variables apply to all repos (useful for shared config like `ILTERO_API_URL`)
- **Repository** secrets/variables are per-repo
- **Environment** secrets/variables apply only when a job has `environment: production` set — the strongest isolation

---

## Workflow Permissions

Follow the principle of least privilege. At the workflow level, set the default restrictively:

```yaml
permissions:
  contents: read
```

Then grant additional permissions only to jobs that need them:

```yaml
jobs:
  compliance:
    permissions:
      contents: read
      id-token: write        # Required for OIDC
      pull-requests: write   # Required for PR comments
    steps: ...

  deploy:
    permissions:
      contents: read
      id-token: write        # Required for AWS OIDC
      deployments: write     # Required for GitHub Deployments
    steps: ...
```

Avoid `permissions: write-all` — it grants full access to everything, including the ability to push code.

See [`examples/security-hardened.yml`](../examples/security-hardened.yml) for a multi-job setup with correctly-scoped permissions.

---

## Public Repositories and Fork PRs

If your repo is public, anyone can open a pull request. This has two security implications:

1. **Workflow runs on untrusted code.** PR builds execute whatever Terraform and workflow changes the PR author submitted. Never run with production credentials on PR events.
2. **Infrastructure details may leak.** Terraform plan output includes resource names, account IDs, VPC CIDRs, security group rules, IAM ARNs, etc. Anyone who can read the workflow run can see these.

Mitigations:

- **Require approval for first-time contributors.** Settings → Actions → General → "Require approval for first-time contributors" (or "all outside collaborators" for stricter posture).
- **Use `pull_request`, not `pull_request_target`.** `pull_request_target` runs with repo secrets even on fork PRs, which is a known attack vector. Iltero's generated workflows use `pull_request`.
- **Give the compliance role read-only AWS permissions.** The compliance job runs `terraform plan`, which should be read-only. Use a separate, more privileged role only for the deploy job (which requires `github.event_name == 'push'`).

---

## Further reading

- [GitHub: Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)
- [GitHub: Using third-party actions](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)
- [SLSA framework: Build integrity](https://slsa.dev/)
- [zizmor rule reference](https://woodruffw.github.io/zizmor/audits/)
- [GitHub Security Lab: Preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/)
