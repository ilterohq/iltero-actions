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

### Moving the Iltero CLI pin

The `setup` action installs the Iltero CLI and iltero-schemas at the commits named in `setup/cli-sources.txt`, and
every other package from `setup/cli-requirements.txt`. To move either commit, run `scripts/lock-cli.py` from the
repository root. It rewrites both files:

```bash
scripts/lock-cli.py CLI_CHECKOUT SCHEMAS_COMMIT
```

`CLI_CHECKOUT` is a checkout of iltero-cli at the commit to pin, and `SCHEMAS_COMMIT` is the iltero-schemas commit
that CLI commit is tested against. Never edit either file by hand.

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

A maintainer makes a release with the Release workflow. First, move the changes under "Unreleased" in
[CHANGELOG.md](CHANGELOG.md) into a section for the new version, such as `## [0.3.0] - 2026-11-20`, and merge that
to `main`. Then start the workflow by hand on `main`, with the version:

```bash
gh workflow run release.yml --ref main -f version=v0.3.0
```

The workflow publishes nothing until every step passes:

1. It checks that the run is on `main`, that the version has the form `vX.Y.Z`, that no tag for that version exists,
   that `CHANGELOG.md` has a section for it, and that the Iltero CLI and schemas commits pinned in
   `setup/cli-sources.txt` are on the `main` branch of their repositories.
2. It runs CI on the commit being released.
3. It creates the version's tag at that commit, then the GitHub release on that tag, with the version's
   `CHANGELOG.md` section as its notes. A version with a suffix, such as `v0.3.0-rc.1`, is published as a pre-release.

A run started on another branch publishes nothing: every job shows as skipped.
