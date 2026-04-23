# Contributing to Iltero Actions

Thank you for your interest in contributing to Iltero Actions! We welcome contributions from the community.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Developer Certificate of Origin](#developer-certificate-of-origin)
- [Pull Request Process](#pull-request-process)
- [Testing](#testing)
- [Documentation](#documentation)

## Code of Conduct

This project adheres to a Code of Conduct. By participating, you are expected to uphold this code.
Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:

   ```bash
   git clone https://github.com/YOUR-USERNAME/iltero-actions.git
   cd iltero-actions
   ```

3. **Add upstream remote**:

   ```bash
   git remote add upstream https://github.com/ilterohq/iltero-actions.git
   ```

## Development Setup

### Prerequisites

- Bash 4.0 or higher
- Git
- A GitHub account
- Docker (optional, for testing)

### Project Structure

```text
iltero-actions/
├── action.yml                     # Root orchestration action
├── setup/action.yml               # Install tools
├── setup-oidc/action.yml          # OIDC authentication
├── configure-registry/action.yml  # Registry auth
├── scan/action.yml                # Static scanning
├── evaluate/action.yml            # Plan evaluation
├── deploy/action.yml              # Deployment action
├── monitor/action.yml             # Drift detection & runtime compliance
├── actions/                       # Internal composite actions
│   ├── setup-iltero-cli/
│   ├── setup-toolchain/
│   └── parse-units/
├── scripts/                       # Pipeline scripts
│   ├── run-pipeline.sh
│   ├── detect-environment.sh
│   ├── detect-stacks.sh
│   └── lib/
├── schemas/                       # JSON Schema
└── examples/                      # Example workflows
```

### Local Testing

Test scripts locally:

```bash
# Test environment detection
./scripts/detect-environment.sh /path/to/config.yml

# Run shellcheck on scripts
shellcheck scripts/*.sh scripts/lib/*.sh
```

## Making Changes

### Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/your-bug-fix
```

**Branch Naming Convention:**

- `feat/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation changes
- `refactor/` - Code refactoring
- `test/` - Test improvements

### Commit Messages

Write clear, concise commit messages following this format:

```text
<type>: <subject>

<body>

<footer>
```

**Types:**

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code formatting (no functional changes)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Example:**

```text
feat: add registry configuration action

Implement configure-registry action to handle private module
authentication via .netrc and git URL rewriting.

Closes #123
```

## Developer Certificate of Origin

By contributing to this project, you certify that:

1. The contribution was created in whole or in part by you and you have the right
   to submit it under the Apache 2.0 license.
2. The contribution is based upon previous work that, to the best of your knowledge,
   is covered under an appropriate open source license and you have the right under
   that license to submit that work with modifications.
3. The contribution was provided directly to you by some other person who certified
   (1) or (2) and you have not modified it.
4. You understand and agree that this project and the contribution are public and
   that a record of the contribution is maintained indefinitely.

### Sign Your Commits

All commits must be signed off using the Developer Certificate of Origin (DCO).
This is done by adding a `Signed-off-by` line to your commit messages:

```bash
git commit -s -m "feat: add new feature"
```

This adds:

```text
Signed-off-by: Your Name <your.email@example.com>
```

**Configure Git for DCO:**

```bash
git config user.name "Your Name"
git config user.email "your.email@example.com"
```

**Note:** We use DCO instead of a Contributor License Agreement (CLA) to reduce
friction for contributors while maintaining legal clarity.

## Pull Request Process

### Before Submitting

1. **Sync with upstream:**

   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Run shellcheck on scripts:**

   ```bash
   shellcheck scripts/*.sh scripts/lib/*.sh
   ```

3. **Validate action.yml files:**

   ```bash
   # Use actionlint if available
   actionlint action.yml setup/action.yml setup-oidc/action.yml \
       scan/action.yml evaluate/action.yml deploy/action.yml \
       monitor/action.yml configure-registry/action.yml
   ```

4. **Test locally** if possible

5. **Update documentation** if needed

6. **Ensure all commits are signed off** (DCO)

### Submitting the PR

1. Push your branch to your fork:

   ```bash
   git push origin feature/your-feature-name
   ```

2. Open a Pull Request on GitHub

3. Fill out the PR template with:
   - **Description** of the change
   - **Related issues** (e.g., "Closes #123")
   - **Testing** performed
   - **Screenshots** (if UI changes)

### PR Review Process

- A maintainer will review your PR within 3-5 business days
- Address review feedback by pushing new commits
- Once approved, a maintainer will merge your PR
- Your contribution will be included in the next release

### PR Checklist

- [ ] Code follows the project's coding standards
- [ ] Scripts pass shellcheck
- [ ] Action files are valid YAML
- [ ] Documentation updated
- [ ] All commits are signed off (DCO)
- [ ] PR title is clear and descriptive
- [ ] Related issues are linked

## Coding Standards

### Shell Scripts

We follow Google's [Shell Style Guide](https://google.github.io/styleguide/shellguide.html):

- Use `#!/bin/bash` shebang
- Use `set -euo pipefail` for error handling
- Quote all variables: `"$var"` not `$var`
- Use `$(command)` instead of backticks
- Functions should be lowercase with underscores

**Example:**

```bash
#!/bin/bash
set -euo pipefail

# Detect environment from git ref
detect_environment() {
    local config_file="$1"
    local current_branch

    current_branch=$(git rev-parse --abbrev-ref HEAD)

    # Search environments for matching git_ref.name
    yq eval ".environments | to_entries | .[] | select(.value.git_ref.name == \"$current_branch\") | .key" "$config_file"
}
```

### GitHub Actions YAML

- Use descriptive names for steps
- Document inputs and outputs
- Use composite actions for reusability
- Pin action versions

### Code Quality Tools

We use:

- **shellcheck**: Shell script linter
- **actionlint**: GitHub Actions workflow linter
- **yamllint**: YAML linter

## Testing

### Manual Testing

Test against a sample repository:

1. Create a test repo with terraform stacks
2. Reference your fork's action
3. Verify workflow runs correctly

```yaml
# In test repo's workflow
- uses: YOUR-USERNAME/iltero-actions@your-branch
  with:
    stacks_path: infra/stacks
```

### Testing Scripts

```bash
# Test with sample config
export STACKS_PATH="test/fixtures/stacks"
export GITHUB_REF="refs/heads/main"
./scripts/detect-environment.sh test/fixtures/stacks/sample/config.yml

# Run shellcheck
shellcheck -x scripts/*.sh scripts/lib/*.sh
```

## Documentation

### README Updates

Update the README when:

- Adding new actions
- Changing inputs/outputs
- Adding new features
- Changing configuration options

### Example Workflows

Add or update examples in `examples/` for:

- New use cases
- Complex configurations
- Best practices

### Inline Documentation

Document scripts with:

- Header explaining purpose
- Function docstrings
- Inline comments for complex logic

## What to Contribute

### Good First Issues

Look for issues labeled `good-first-issue` - these are ideal for first-time contributors.

### Ideas for Contributions

- **Bug fixes**: Check open issues
- **New actions**: Additional granular actions
- **Script improvements**: Better error handling, logging
- **Testing**: Add test fixtures and scripts
- **Documentation**: Improve guides, add examples
- **Error messages**: Make them more helpful

### What We Don't Accept

- Changes without testing
- Breaking changes without discussion
- Code that doesn't follow style guidelines
- Unsigned commits (missing DCO)

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue
- **Security**: Email <security@iltero.io>

## Recognition

Contributors will be:

- Listed in release notes
- Credited in commit history
- Mentioned in the README (for significant contributions)

Thank you for contributing to Iltero Actions! 🎉

---

**Last Updated**: February 24, 2026
