# Iltero Actions

## Use the actions

1. Copy a workflow from [`examples/`](../examples/README.md) into `.github/workflows/`.
2. Replace every `0000000000000000000000000000000000000000` with the full commit SHA: the 40-character ID that
   Git gives each commit. Use the SHA of the iltero-actions commit you use. Pin every action to the same commit.
3. Replace the example values: branches, environments, deploy role and region.

Run `setup` first in every job that uses an Iltero action, except `comment`. `setup` installs the Iltero CLI and its
evaluator. `deploy` and `preview` install Terraform themselves, at the version that their `terraform-version` input
names. A job that uses `record-iac` installs and runs its own Terraform, and a job that uses `record-image` or
`close` runs none.

## Records artifacts

`deploy`, `record-iac` and `record-image` upload their records as a workflow artifact. `verify` uploads its record
bundles the same way. The `artifact-name` input sets the artifact's name. When the input is empty, the action uses the
default below. When the default is not a valid artifact name, the step stops. Set `artifact-name` then.

| Action | Default artifact name |
| --- | --- |
| `deploy` | `iltero-deploy-<environment>` |
| `verify` | `iltero-record-bundles-<environment>` |
| `record-iac` | `iltero-records-<environment>-<unit>` |
| `record-image`, `plan` stage | `iltero-image-records-<unit>` |
| `record-image`, deployment stages | `iltero-image-deployment-records-<environment>-<unit>` |

When `write-report` is `true`, `deploy`, `verify` and `record-iac` upload their reports as a second artifact, named
`<artifact-name>-report`. GitHub keeps these artifacts for as long as the repository's or organization's artifact
retention setting says. `preview` keeps its records artifact for 30 days, and its comment artifact for 1 day.

## Pre-deploy in a project with no platform section

In a project with no `platform` section, list `pre_deploy` under `stages.out_of_scope` in `.iltero/config.yml`.
`deploy` and `record-iac` do not run the pre-deploy stage there, because it checks facts that only Iltero Platform
holds.

Both ask the CLI instead, with `iltero record in-scope`, whether the unit's record from the plan stage expects the
pre-deploy stage. Before it answers, the CLI verifies the record: it checks that the record and the files it cites
are unchanged. When the records directory holds no record of the unit, or the CLI cannot answer, the step stops. When
the record expects the pre-deploy stage, the step warns, and the job summary reads `not run`. Otherwise the job
summary reads `not in scope`. The job summary's details show the CLI's answer.

## Unit settings

`deploy` and `preview` read a unit's settings for an environment from the unit's own `config/` folder. Both files
are optional.

- **`config/backend/<environment>.hcl`**: backend settings. `deploy` passes the file to `terraform init`.
  `preview` does not read it.
- **`config/<environment>.tfvars.json`**: variable values. `deploy` and `preview` pass the file to `terraform plan`.
  `deploy` also passes it to the two readings it takes for the post-verify stage.

## Units that read other units' state

Terraform's state is the data in which Terraform tracks the resources it manages. A unit that reads another unit's
Terraform state can declare the variable `enable_remote_state_dependencies` in a `.tf` file of its folder. `deploy`
and `preview` then set it in a variables file that they pass after the unit's own.

- **`deploy`** sets it to `true`, so the unit never deploys with placeholder values in place of upstream state.
- **`preview`** sets it to `false`, because it plans with no cloud credential. The unit's result in the job summary
  and the pull request comment reads `exit N (best effort: planned without upstream state)`.

## State check

`deploy` runs `iltero state check` on each unit after `terraform init` and before the plan. The check fails unless
Terraform keeps the unit's state outside its working directory, as a remote backend does. A failed check stops the
deploy at that unit, and the job summary's Plan cell reads `state check exit N`.

`record-iac` runs the same check at the `plan` stage, before the CLI checks the plan. It reads the job's own
`TF_DATA_DIR` when it is set, so run `terraform init` with the same value. A failed check fails the step, and the
job summary's result reads `state check exit N`.

## State not read after the apply

When Terraform cannot read a unit's state after the apply, `deploy` still records the apply. It runs the post-deploy
check with `--state-unreadable` in place of `--state`, and the job summary's Post-deploy cell reads
`exit N, state not read`. The unit fails with the apply's exit code when the apply failed, and otherwise with the CLI's
exit code. Later units are not deployed, and the post-verify stage does not run.

In a job that runs Terraform itself, give `record-iac` the input `state-unreadable: true` at `post_deploy`, and leave
`state` empty. The CLI then records the apply from the apply log alone, and the step fails. The job summary's result
reads `exit N, state not read`. `examples/iac/governed-own-terraform.yml` shows how.

## Post-verify readings of a Terraform unit

The post-verify stage checks that a unit's deployed resources still match what the apply left. When every unit
deployed, `deploy` runs it for each unit whose record expects it. The CLI writes the stages a record expects at the
plan stage, from the run's settings in a governed run or from the project's configuration otherwise. `deploy` asks the
CLI with `iltero record in-scope`, and the job summary's details show the CLI's answer. When the CLI cannot answer
for a unit, that unit's Post-verify cell reads `record does not verify` for exit code 9, or `record unreadable` for
any other code. `deploy` goes on with the other units, and the step then fails with the first failing code.

For each such unit, `deploy` reads the deployed resources back twice with `terraform plan -refresh-only`. It saves each
reading and never applies it. The second reading comes at least 61 seconds after the first. A unit that fails the
stage does not stop the others. The step then fails with the first failing code.

The readings can hold secret values, because Terraform does not mark every secret as sensitive. `deploy` does not
upload them, and they are not meant to be kept: the record holds only each reading's SHA-256 digest. The
`readings-directory` output names their directory, as `<unit>/first.json` and `<unit>/second.json`.

## Image deployment

`record-image` records a deployment of an image in three stages, into one record: `pre_deploy` before the deployment,
`post_deploy` after it, and `post_verify` after the rollout.

Every stage of a deployment takes `environment`. At `post_deploy` and `post_verify`, it must match the environment in
the record.

In a project linked to Iltero Platform, each stage runs in an image deploy run: a governed run that deploys one
application's image to one environment. Each stage takes `application`, and Iltero Platform finds or opens the image
deploy run of the pipeline run for that application and environment. Each stage sends its record. The run's settings
on Iltero Platform say which stages the record expects: `pre_deploy` and `post_deploy` always, and `post_verify` when
the environment's policy requires it. The run's settings also decide whether a failed or undecided assertion fails
`pre_deploy`, so the CLI refuses `advisory: true` at every stage of an image deploy run. The `close` action closes the
run when it is given both `application` and `environment`.

In a project with no `platform` section, `record-image` records the deployment on the runner alone and sends nothing
to Iltero Platform. A check on the runner alone reads no approvals and does not know whether each commit was
reviewed, so an assertion that reads either is always undecided at `pre_deploy`. `post_deploy` and `post_verify`
refuse `advisory: true`.

- **`pre_deploy`** checks the image to deploy, named by its digest with no tag. It always checks that Iltero Platform
  accepted a build of the image for the environment.
  - In a linked project, record and send the build first, with the `plan` stage of `record-image`. Let that step
    finish before the deployment's `pre_deploy` starts.
  - In a project with no `platform` section, the build check is always undecided, because only Iltero Platform accepts
    a build. `pre_deploy` therefore fails unless `advisory: true` is set. With `advisory: true`, failed and undecided
    assertions do not fail the step, and the record still shows them.
- **`post_deploy`** reports the image the deployment says it deployed.
- **`post_verify`** checks that every pod of the workload runs the deployed image. The job reads the workload, its pods,
  a Deployment's ReplicaSets, and the workload again, in that order, with `kubectl get --raw`. It passes the files as
  `workload-before-pods-listing`, `pods`, `pod-owners` and `workload-after-pods-listing`, with the uid of the
  cluster's `kube-system` namespace as `cluster-id`.

Each stage after `pre_deploy` reads the record from `records-directory`. When a later stage runs in a different job
from `pre_deploy`, that job downloads the records artifact of the earlier job and passes its directory as
`records-directory`. Each deployment needs a records directory that holds no record of its unit.

The readings of the workload can hold secret values, such as a container's environment. Keep them in
`$RUNNER_TEMP`, and do not upload them. The record keeps only a redacted copy.

## What a job needs

- **`permissions: {}`** at the workflow level, and per-job permissions that grant only what the job needs.
- **`contents: read`** in a job that checks out the repository. The `close` job checks it out too, because `close`
  reads the project's `.iltero/config.yml`.
- **`id-token: write`** in a job that calls Iltero Platform: `close`, and `deploy`, `record-iac` or `record-image` at
  any stage, in a linked project. On `pull_request` events, `record-iac` and `record-image` check locally and need
  none.
  The Iltero CLI requests the job's GitHub identity token itself. The examples also grant it for the AWS role the job
  signs in with.
- **`ILTERO_API_URL`**, the address of Iltero Platform, in a workflow that calls it. It is the only Iltero setting.
  The job holds no Iltero secret.
- **Cloud credentials** in a job that sets `store-records: true`. The CLI keeps each record in the run's artifact
  store, the bucket that Iltero Platform names for the run, with the job's own credentials. On AWS, set them with
  `aws-actions/configure-aws-credentials` and OpenID Connect (OIDC) before the step. Grant the role only the
  permissions below, on the Amazon Simple Storage Service (S3) bucket and its key. Each resource is named by its
  Amazon Resource Name (ARN). `<prefix>` is the storage location's base prefix, empty when it has none.

  | Permission | On |
  | --- | --- |
  | `s3:PutObject`, `s3:PutObjectRetention`, `s3:GetObjectRetention` | `arn:aws:s3:::BUCKET/<prefix>artifacts/<organization id>/*` |
  | `kms:GenerateDataKey` | The bucket's Key Management Service (KMS) key, restricted with the `kms:ViaService` condition to S3 in the bucket's region |

  The role, the bucket and its key must be in the same AWS account. S3 refuses a bucket in another account.

`preview` needs only `contents: read`. With `registry-host` set, it also needs `id-token: write`, because
`terraform init` downloads private modules with the job's GitHub identity token. The project must then be linked to
Iltero Platform.

`comment` needs only `pull-requests: write`. It runs in its own job, after `preview`, and runs no code from the pull
request. GitHub gives a pull request from a fork or from Dependabot a read-only token, so `comment` posts nothing for
it and leaves a notice.

`preview` and `comment` run only on `pull_request` events.

The actions refuse `pull_request_target` and `workflow_run` events. `deploy` and `close` also refuse
`pull_request` events. Use `preview` on pull requests. On `pull_request` events, `record-iac` and `record-image`
record only the `plan` stage. `record-iac` and `record-image` refuse `pull_request_review` and
`pull_request_review_comment` events.

On a pull request, `preview` and `record-iac` check each plan locally, and `record-image` checks the image locally,
also for a project linked to Iltero Platform. `record-image` checks it as advice there: failed or undecided assertions
do not fail the step.
A local check never contacts Iltero Platform, and its record is not evidence of the change. It checks the project's
own assertions. The checks after the merge use the assertions that Iltero Platform sets, so their results can differ.

## Contribute

Before opening a pull request, run the checks that continuous integration (CI) runs:

```bash
{ find scripts -name '*.sh' -type f; echo tests/test_helper.bash; } | xargs shellcheck --severity=style
actionlint
actionlint examples/*/*.yml
zizmor . examples/*/*.yml
yamllint -c .yamllint.yml .
git ls-files -z -- '*.py' | xargs -0 -r python3 -I -m py_compile
git ls-files -z | python3 -I scripts/find-nul-bytes.py
find scripts -name '*.sh' -type f -print0 | xargs -0 -n1 bash -n
bats -r tests/
npx -y markdownlint-cli2@0.23.2 README.md CONTRIBUTING.md CHANGELOG.md SECURITY.md CODE_OF_CONDUCT.md \
  docs/*.md examples/*.md .github/*.md
```

The Python lines check the syntax of every Python file and that no file holds a NUL byte. The `bash -n` line checks
the syntax of every shell script under `scripts/`. CI also scans the repository for secrets with TruffleHog. That
scan runs only in CI. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the pull request process.
