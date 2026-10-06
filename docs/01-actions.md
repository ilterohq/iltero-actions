# Actions

Each action is a composite action in its own folder. Pin every action to a full commit SHA:

```yaml
uses: ilterohq/iltero-actions/<action>@<commit-sha>  # vX.Y.Z
```

Every action refuses to run on `pull_request_target` and `workflow_run` events. Every action needs a Linux runner,
X64 or ARM64.

| Action | Purpose |
| --- | --- |
| [`setup`](#setup) | Install Terraform, the Iltero CLI and its evaluator |

## setup

`setup` installs the tools the other actions use. Each tool is checked before it is used:

- **Terraform** is downloaded from HashiCorp's releases. The action refuses the archive unless its SHA-256 digest
  matches the digest pinned in this release.
- **The Iltero CLI** is installed at the commit pinned in this release. Every package it depends on is installed
  from a lock file and must match its pinned hash.
- **The evaluator** (Open Policy Agent, which the CLI uses to check rules) is downloaded at the version the CLI pins.
  The action refuses it unless its digest matches the CLI's pin.

The action then runs `iltero doctor`, and fails unless the CLI reports that it is ready.

The tools are installed under the runner's temporary directory. They are not added to `PATH`. Use the output paths.

### Inputs

| Input | Description | Default |
| --- | --- | --- |
| `terraform-version` | The Terraform version to install. Only the versions pinned in this release are accepted. | `1.16.5` |

### Outputs

| Output | Description |
| --- | --- |
| `terraform-version` | The Terraform version installed. |
| `terraform-path` | Absolute path of the Terraform binary. |
| `cli-commit` | The Iltero CLI commit installed. |
| `cli-path` | Absolute path of the `iltero` command. |
| `opa-path` | Absolute path of the evaluator. Set `ILTERO_OPA_PATH` to it when you run `iltero`. |

### Example

```yaml
jobs:
  check:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<commit-sha>  # vX.Y.Z
        with:
          persist-credentials: false
      - id: setup
        uses: ilterohq/iltero-actions/setup@<commit-sha>  # vX.Y.Z
      - env:
          ILTERO: ${{ steps.setup.outputs.cli-path }}
          ILTERO_OPA_PATH: ${{ steps.setup.outputs.opa-path }}
        run: '"${ILTERO}" doctor'
```
