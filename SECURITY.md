# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | Yes                |
| < 1.0   | No                 |

## Reporting a Vulnerability

We take the security of Iltero Actions seriously. If you discover a security vulnerability, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

### How to Report

Email **<security@iltero.io>** with:

- A description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Any suggested fixes (optional)

### What to Expect

- **Acknowledgment**: We will acknowledge receipt within 2 business days
- **Assessment**: We will assess the vulnerability within 5 business days
- **Resolution**: We aim to release a fix within 30 days for confirmed vulnerabilities
- **Disclosure**: We will coordinate public disclosure with you after the fix is released

### Scope

The following are in scope for security reports:

- Secret/credential exposure in action outputs or logs
- Injection vulnerabilities in shell scripts (command injection, path traversal)
- Insecure handling of GitHub tokens or Iltero API tokens
- Privilege escalation through action inputs
- Supply chain risks in action dependencies

The following are **out of scope**:

- Vulnerabilities in third-party actions we reference (report to those maintainers)
- Issues requiring physical access to the runner
- Social engineering attacks
- Denial of service against GitHub Actions infrastructure

## Security Best Practices for Users

- Store `ILTERO_TOKEN` and `ILTERO_REGISTRY_TOKEN` as GitHub Secrets
- Use OIDC for cloud provider authentication when possible
- Enable GitHub branch protection on your main branch
- Review action version pins regularly
- Use least-privilege permissions in workflow files
