# Contributing to Iltero Actions

## Code of Conduct

This project follows a Code of Conduct. Everyone who takes part is expected to uphold it. Read
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## Making changes

1. Fork the repository and create a branch from `main`.
2. Make the change, with tests for every rule it adds.
3. Run the checks that continuous integration (CI) runs, as listed under "Contribute" in
   [docs/README.md](docs/README.md#contribute).
4. Add an entry under "Unreleased" in [CHANGELOG.md](CHANGELOG.md) for every change a user sees.
5. Open a pull request against `main`.

### Commit messages

Use `<type>(<scope>): <subject>`, where type is one of `feat`, `fix`, `docs`, `refactor`, `test`, `ci` or `chore`.
The scope, such as `deploy`, is optional: `<type>: <subject>` is valid too. The subject says what changed in plain
words. Pull request titles use the same format.

### GitHub Actions rules

- Pin every `uses:` to a full commit SHA (the commit's 40-character ID), with a `# vX.Y.Z` comment.
- Never use `${{ }}` inside a `run:` block. Pass values through `env:`.
- Grant permissions per job, and only what the job needs.

## Developer Certificate of Origin

Each contribution is made under the Developer Certificate of Origin (DCO). By contributing to this project, you
certify that:

1. The contribution was created in whole or in part by you and you have the right
   to submit it under the Apache 2.0 license.
2. The contribution is based upon previous work that, to the best of your knowledge,
   is covered under an appropriate open source license and you have the right under
   that license to submit that work with modifications.
3. The contribution was provided directly to you by some other person who certified
   (1) or (2) and you have not modified it.
4. You understand and agree that this project and the contribution are public and
   that a record of the contribution is maintained indefinitely.

### Sign your commits

Sign off every commit with a `Signed-off-by` line in its message:

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

The project uses the DCO instead of a Contributor License Agreement (CLA).

## Releases and signing

Two policies are enforced by repository rulesets.

### Cryptographically signed commits

Commits on `main` must carry a verified signature (separate from the DCO
`Signed-off-by` line above). Set up SSH commit signing once:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

Then register the **same** key on GitHub as a *Signing Key* (Settings → SSH and
GPG keys → New SSH key → Key type: Signing Key), or:

```bash
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "commit signing"
```

Your commit email must be a verified email on your GitHub account, or commits
show as "Unverified".

### Pinning and immutable tags

- There are no floating major tags. Pin each action to a commit SHA:

  ```yaml
  uses: ilterohq/iltero-actions/<action>@<commit-sha>  # v0.3.0
  ```

- Published tags are immutable. A ruleset blocks moving or deleting a tag, so a version always points at the same
  commit.

### Publishing a release

A release is a GitHub release on a signed `vX.Y.Z` tag. When the release is published, the Release workflow checks
that the tag has the `vX.Y.Z` format and runs CI on the tagged commit.
