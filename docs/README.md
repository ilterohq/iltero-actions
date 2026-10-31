# Iltero Actions notes

Short notes for authors of workflows that use the actions, and for people who change them.

## Use the actions

1. Copy a workflow from [`examples/`](../examples/README.md) into `.github/workflows/`.
2. Replace every `0000000000000000000000000000000000000000` with the full commit SHA of this repository you use. Pin
   every action to the same commit.
3. Replace the example values: branches, environments, cloud role and region.

Run `setup` first in every job except the `comment` job. `setup` installs Terraform for `deploy` and `preview`, which
run it. In a job that installs and runs its own Terraform and uses `record-iac`, set `install-terraform: false`.

## Unit settings

`deploy` and `preview` read a unit's settings for an environment from the unit's own `config/` folder. Both files
are optional.

- **`config/backend/<environment>.hcl`**: backend settings. `deploy` passes the file to `terraform init`.
  `preview` does not read it.
- **`config/<environment>.tfvars.json`**: variable values. `deploy` and `preview` pass the file to `terraform plan`.
  `deploy` also passes it to the two readings it takes for the post-verify stage.

## Post-verify readings

The post-verify stage checks that a unit's deployed resources still match what the apply left. When every unit
deployed, `deploy` runs it for each unit whose record expects it. The CLI writes the stages a record expects at the
plan stage, from the run's settings in a governed run or from the project's configuration otherwise.

For each such unit, `deploy` reads the deployed resources back twice with `terraform plan -refresh-only`. It saves each
reading and never applies it. The second reading comes at least 61 seconds after the first. A unit that fails the
stage does not stop the others. The step then fails with the first failing code.

The readings can hold secret values, because Terraform does not mark every secret as sensitive. `deploy` does not
upload them, and they are not meant to be kept: the record holds only each reading's SHA-256 digest. The
`readings-directory` output names their folder, as `<unit>/first.json` and `<unit>/second.json`.

## What a job needs

- **`permissions: {}`** at the workflow level, and per-job permissions that grant only what the job needs.
- **`contents: read`** in a job that checks out the repository. The `close` job checks it out too, because `close`
  reads the stack's `.iltero/config.yml`.
- **`id-token: write`** in a job that calls Iltero Platform: `close`, and `deploy` or `record-iac` for a linked project.
  The Iltero CLI requests the job's GitHub identity token itself. The examples also grant it for the cloud role.
- **`ILTERO_API_URL`**, the address of Iltero Platform, in a workflow that calls it. It is the only Iltero setting.
  The job holds no Iltero secret.

`preview` needs only `contents: read`. With `registry-host` set, it also needs `id-token: write`, because
`terraform init` downloads private modules with the job's GitHub identity token. The project must then be linked to
Iltero Platform.

`comment` needs only `pull-requests: write`. It runs in its own job, after `preview`, and runs no code from the pull
request. GitHub gives a pull request from a fork or from Dependabot a read-only token, so `comment` posts nothing for
it and leaves a notice.

The actions refuse `pull_request_target` and `workflow_run` events. `deploy` and `close` also refuse
`pull_request` events. Use `preview` on pull requests. On `pull_request` events, `record-iac` records only the `plan`
stage. It refuses `pull_request_review` and `pull_request_review_comment` events. `comment` runs only on
`pull_request` events.

On a pull request, `preview` and `record-iac` check each plan locally, also for a project linked to Iltero Platform.
A local check never contacts Iltero Platform, and its record is not evidence of the change. It checks the project's
own assertions. The checks after the merge use the assertions that Iltero Platform sets, so their results can differ.

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
