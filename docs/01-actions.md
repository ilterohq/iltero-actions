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
| [`open`](#open) | Open a governed run on Iltero Cloud |
| [`close`](#close) | Close a governed run |

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

## open

`open` opens a governed run for one stack and one environment, starting from the plan stage. It runs
`iltero cloud run open`. The CLI requests the job's GitHub identity token itself, and Iltero Cloud checks that this
workflow may deploy to that environment.

`open` refuses pull request events. A pull request runs a local check only. The job needs `id-token: write`, the
`setup` action earlier in the same job, and the `ILTERO_API_URL` environment variable. The step fails with the CLI's
exit code.

### Inputs

| Input | Description | Default |
| --- | --- | --- |
| `stack-id` | The stack the run is for, as a UUID. | required |
| `environment` | The environment the run deploys to. | required |

### Outputs

| Output | Description |
| --- | --- |
| `run-id` | The run's id. Pass it to every later job of the pipeline. |
| `pins-digest` | The digest of the run's pins. Pass it to every later job of the pipeline. |

## close

`close` closes a governed run. It runs `iltero cloud run close` and lists every check the run owed and never got.
Run it in a job after every other job of the pipeline, and only when they succeeded, so a failed pipeline stays open
for a re-run.

`close` has the same requirements as `open`.

### Inputs

| Input | Description | Default |
| --- | --- | --- |
| `run-id` | The run to close, as output by `open`. | required |

### Example

```yaml
env:
  ILTERO_API_URL: https://api.iltero.io

jobs:
  deploy:
    runs-on: ubuntu-24.04
    environment: production
    permissions:
      contents: read
      id-token: write
    outputs:
      run-id: ${{ steps.open.outputs.run-id }}
    steps:
      - uses: actions/checkout@<commit-sha>  # vX.Y.Z
        with:
          persist-credentials: false
      - uses: ilterohq/iltero-actions/setup@<commit-sha>  # vX.Y.Z
      - id: open
        uses: ilterohq/iltero-actions/open@<commit-sha>  # vX.Y.Z
        with:
          stack-id: 0b6f1f3e-5d7c-4c8e-9a3b-2f1e0d9c8b7a
          environment: production

  close:
    needs: deploy
    if: success()
    runs-on: ubuntu-24.04
    permissions:
      id-token: write
    steps:
      - uses: ilterohq/iltero-actions/setup@<commit-sha>  # vX.Y.Z
      - uses: ilterohq/iltero-actions/close@<commit-sha>  # vX.Y.Z
        with:
          run-id: ${{ needs.deploy.outputs.run-id }}
```
