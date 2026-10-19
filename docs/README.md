# Iltero Actions notes

Short notes for authors of workflows that use the actions, and for people who change them.

## Use the actions

1. Copy a workflow from [`examples/`](../examples/README.md) into `.github/workflows/`.
2. Replace every `0000000000000000000000000000000000000000` with the full commit SHA of this repository you use. Pin
   every action to the same commit.
3. Replace the example values: branches, environments, cloud role and region.

Run `setup` first in every job except the `comment` job.

## Unit settings

`deploy` and `preview` read a unit's settings for an environment from the unit's own `config/` folder. Both files
are optional.

- **`config/backend/<environment>.hcl`**: backend settings. `deploy` passes the file to `terraform init`.
  `preview` does not read it.
- **`config/<environment>.tfvars.json`**: variable values. `deploy` and `preview` pass the file to `terraform plan`.

## What a job needs

- **`permissions: {}`** at the workflow level, and per-job permissions that grant only what the job needs.
- **`contents: read`** in a job that checks out the repository.
- **`id-token: write`** in a job that calls Iltero Platform: `open`, `close`, and `deploy` for a linked project. The
  Iltero CLI requests the job's GitHub identity token itself. The examples also grant it for the cloud role.
- **`ILTERO_API_URL`**, the address of Iltero Platform, in a workflow that calls it. It is the only Iltero setting.
  The job holds no Iltero secret.

`preview` needs only `contents: read`. With `registry-host` set, it also needs `id-token: write`, because
`terraform init` downloads private modules with the job's GitHub identity token. The project must then be linked to
Iltero Platform.

`comment` needs only `pull-requests: write`. It runs in its own job, after `preview`, and runs no code from the pull
request. GitHub gives a pull request from a fork or from Dependabot a read-only token, so `comment` posts nothing for
it and leaves a notice.

The actions refuse `pull_request_target` and `workflow_run` events. `open`, `deploy` and `close` also refuse
`pull_request` events. Use `preview` on pull requests. `comment` runs only on `pull_request` events.

## Contribute

Run the checks CI runs before opening a pull request:

```bash
shellcheck --severity=style scripts/*.sh scripts/lib/*.sh
actionlint
actionlint examples/*.yml
zizmor .
yamllint -c .yamllint.yml .
bats tests/
```

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the pull request process.
