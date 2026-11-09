# Security Policy

## Supported Versions

Only the latest release receives security fixes. This repository has no release yet.

## Reporting a Vulnerability

Report a security vulnerability in Iltero Actions privately, by email.

**Do not open a public GitHub issue for a security vulnerability.**

### How to Report

Email **<security@iltero.io>** with:

- A description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Any suggested fixes (optional)

### What to Expect

- **Acknowledgment**: Iltero acknowledges receipt within 2 business days
- **Assessment**: Iltero assesses the vulnerability within 5 business days
- **Resolution**: Iltero aims to release a fix within 30 days for confirmed vulnerabilities
- **Disclosure**: Iltero coordinates public disclosure with you after the fix is released

### Scope

The following are in scope for security reports:

- Secret or credential exposure in action outputs or logs
- Injection vulnerabilities in shell scripts (command injection, path traversal)
- Insecure handling of GitHub tokens or identity tokens
- Privilege escalation through action inputs
- Supply chain risks in action dependencies

The following are **out of scope**:

- Vulnerabilities in third-party actions that these actions use (report them to their maintainers)
- Issues requiring physical access to the runner
- Social engineering attacks
- Denial of service against GitHub Actions infrastructure

## Security Best Practices for Users

- Use OpenID Connect (OIDC) for cloud provider authentication. Never store long-lived cloud keys as secrets
- Enable GitHub branch protection on your main branch
- Pin every action to a full commit SHA (the commit's 40-character ID) and review the pins regularly
- Use least-privilege permissions in workflow files
