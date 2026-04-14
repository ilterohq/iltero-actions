# Authentication

This guide covers the two authentication concerns in an Iltero Actions workflow:

1. **Iltero tokens** — so the action can call the Iltero API
2. **AWS credentials** — so Terraform can plan and apply against your cloud account

For each, OIDC is the recommended approach: no long-lived secrets to rotate, short-lived tokens, and every credential exchange is auditable.

## Table of Contents

- [Iltero Tokens](#iltero-tokens)
  - [Option A: OIDC (Recommended)](#option-a-oidc-recommended)
  - [Option B: Token-Based Auth](#option-b-token-based-auth)
- [AWS Credentials](#aws-credentials)
  - [Option A: OIDC (Recommended)](#option-a-oidc-recommended-1)
  - [Option B: Access Keys](#option-b-access-keys)

---

## Iltero Tokens

### Option A: OIDC (Recommended)

OIDC exchanges a GitHub Actions token for short-lived Iltero credentials. No secrets to rotate.

**Root action** (simplest):

```yaml
- uses: ilterohq/iltero-actions@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    oidc: 'true'
    stack_id: ${{ vars.ILTERO_STACK_ID }}
    org_id: ${{ vars.ILTERO_ORG_ID }}
  # env:
  #   ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}  # Optional, defaults to https://api.iltero.io
```

**Granular actions** (setup + setup-oidc):

```yaml
- uses: ilterohq/iltero-actions/setup@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
- uses: ilterohq/iltero-actions/setup-oidc@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    stack-id: ${{ vars.ILTERO_STACK_ID }}
    org-id: ${{ vars.ILTERO_ORG_ID }}
```

**Prerequisites:**

- `permissions: { id-token: write }` on the workflow or job
- A PipelinePrincipal configured in Iltero for the repository
- `ILTERO_STACK_ID` and `ILTERO_ORG_ID` stored as repository **variables** (not secrets — these are not sensitive)

### Option B: Token-Based Auth

If OIDC is not an option, use long-lived secrets. Less secure because these tokens don't expire automatically and must be rotated manually.

| Secret | Purpose | Source |
|--------|---------|--------|
| `ILTERO_TOKEN` | API authentication | Dashboard → Settings → API Tokens |
| `ILTERO_REGISTRY_TOKEN` | Private modules | Dashboard → Settings → Registry Tokens |

```yaml
- uses: ilterohq/iltero-actions@41bada1ab6681a6de40b2584a109a177f7345d06 # v1
  with:
    stacks_path: infra/stacks
  env:
    ILTERO_API_URL: ${{ vars.ILTERO_API_URL }}
    ILTERO_TOKEN: ${{ secrets.ILTERO_TOKEN }}
    ILTERO_REGISTRY_TOKEN: ${{ secrets.ILTERO_REGISTRY_TOKEN }}
```

---

## AWS Credentials

### Option A: OIDC (Recommended)

Use [`aws-actions/configure-aws-credentials`](https://github.com/aws-actions/configure-aws-credentials) to assume an IAM role via OIDC. No access keys stored in GitHub.

```yaml
- uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: ${{ vars.AWS_REGION }}
```

**One-time AWS setup:**

1. Create an IAM OIDC identity provider:
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   ```

2. Create an IAM role with a trust policy scoped to your repository. Example (replace `ACCOUNT_ID`, `ORG`, `REPO`):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
       },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
         },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": "repo:ORG/REPO:environment:*"
         }
       }
     }]
   }
   ```

3. Attach the IAM policies your Terraform needs.

**Tip:** use a strict `sub` claim like `repo:ORG/REPO:environment:production` to restrict a role to a specific GitHub Environment. Use separate roles per environment with different permission scopes (read-only for dev, broader for production).

### Option B: Access Keys

Not recommended for production, but useful for getting started or local testing.

```yaml
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  AWS_REGION: ${{ vars.AWS_REGION }}
```

If you use access keys:

- Rotate regularly (every 90 days)
- Scope the IAM user to the minimum permissions Terraform needs
- Never commit them — always use GitHub Secrets
- Prefer `vars` (not secrets) for non-sensitive values like region

---

## Further reading

- [GitHub: About security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [AWS: Configuring OIDC for GitHub Actions](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [examples/oidc.yml](../examples/oidc.yml) — complete OIDC workflow
- [examples/security-hardened.yml](../examples/security-hardened.yml) — hardened multi-environment setup
