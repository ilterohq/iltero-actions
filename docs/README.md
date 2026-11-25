# Iltero Actions

## Use the actions

1. Copy a workflow from [`examples/`](../examples/README.md) into `.github/workflows/`.
2. Replace every `0000000000000000000000000000000000000000` with the commit SHA of the iltero-actions release you use.
   Open the commit linked from the release page and copy its full 40-character ID. Replace each `# v0.3.0` comment
   with that release's version. Use the same release for every action.
3. Replace the example values: branches, environments, deploy role and region.

Run `setup` first in every job that uses an Iltero action, except `comment`. `setup` installs the Iltero CLI and its
evaluator. `deploy` and `preview` install the infrastructure-as-code (IaC) tool themselves: the tool that their `tool`
input names, at the version that their `tool-version` input names. `terraform` is the only supported tool, and the
default. When `tool-version` is empty, they install the version the action pins for the tool: Terraform 1.16.5. They
accept only a version whose checksums `scripts/iac/tools/terraform/checksums.sha256` lists. A job that uses
`record-iac` installs and runs its own Terraform, and a job that uses `record-image` or `close` runs none.

## Records artifacts

`deploy`, `record-iac` and `record-image` upload their records as a workflow artifact. `verify` uploads its record
bundles the same way. Every artifact name ends with `-attempt-<attempt>`, where `<attempt>` is the attempt number of
the pipeline run (on GitHub, the workflow run). A re-run therefore uploads new artifacts and keeps those of earlier
attempts. When the `artifact-name` input is set, the action names the artifact `<artifact-name>-attempt-<attempt>`.
When the input is empty, the action uses the default below. When the resulting name is not a valid artifact name, the
step stops. Set `artifact-name` to a valid name in that case. The `artifact-name` output gives the full name.

| Action | Default artifact name |
| --- | --- |
| `deploy` | `iltero-deploy-<environment>-attempt-<attempt>` |
| `verify` | `iltero-record-bundles-<environment>-attempt-<attempt>` |
| `verify`, with `unit` set | `iltero-record-bundles-<environment>-<unit>-attempt-<attempt>` |
| `record-iac` | `iltero-records-<environment>-<unit>-attempt-<attempt>` |
| `record-image`, `plan` stage | `iltero-image-records-<unit>-attempt-<attempt>` |
| `record-image`, deployment stages | `iltero-image-deployment-records-<environment>-<unit>-attempt-<attempt>` |

When `write-report` is `true`, `deploy`, `verify` and `record-iac` upload their reports as a second artifact, named
`<artifact name>-report`.

The `retention-days` input of `deploy`, `verify`, `record-iac` and `record-image` sets the number of days GitHub keeps
the artifacts the action uploads: a whole number of 1 or more. When the input is empty, the repository's artifact
retention setting applies. Any other value stops the step. `preview` keeps its records artifact for 30 days, and its
comment artifact for 1 day.

## Pre-deploy stage

The pre-deploy stage comes before the apply. Its check reads facts that only Iltero Platform holds, so only a project
linked to Iltero Platform runs it. A project is not linked when `.iltero/config.yml` has no `platform` section.

`deploy` always asks the CLI first, with `iltero record in-scope`, whether the unit's record from the plan stage
requires the stage. `record-iac` asks first only in a project not linked to Iltero Platform. Before it answers, the CLI
checks that the record is consistent with itself and with the files it cites. The job summary's details show the CLI's
answer.

- **`deploy` in a linked project.** When the record requires the stage, `deploy` plans the unit again just before the
  check, against the current state and with the same input variables. It waits one second first when the plan stage's
  plan finished in the current second. It then runs the pre-deploy check on the saved plan file, the plan it made at the
  plan stage, and the new plan. `deploy` applies only the saved plan, never the new plan. When Terraform cannot make the
  new plan, `deploy` stops before that unit's check and apply, and deploys no further unit. The job summary's Pre-deploy
  cell then reads `Terraform failed`. When the record does not require the stage, `deploy` runs no pre-deploy check, the
  job summary reads `not required`, and `deploy` goes on to the apply.
- **`record-iac` in a linked project.** `record-iac` runs the pre-deploy check without asking the CLI first. When the
  environment's policy leaves the stage out, Iltero Platform says so, and the unit's record agrees, the CLI checks
  nothing, adds nothing to the record and exits 0. After a check that passes, `record-iac` therefore asks the CLI
  whether the unit's record requires the stage. When it does not, the job summary reads `not required` instead of
  `passed`. The `plan`, `saved-plan` and `replan` inputs are optional at this stage. `saved-plan` names the saved plan
  file the job will apply, and `plan` names the plan rendered from it with `terraform show -json`. The CLI refuses a
  file or plan other than the one the plan stage checked. `replan` names a new plan that the job makes just before the
  check, with `terraform plan -out=FILE` and `terraform show -json FILE`. The job never applies it. A job that applies a
  plan made in an earlier job must give all three. `examples/iac/governed-own-terraform.yml` shows how.
- **A project not linked to Iltero Platform.** Neither action runs the check. The CLI leaves the stage out of the
  record's scope there by itself. The job summary reads `not required`, and `deploy` goes on to the apply. `record-iac`
  stops when its step gives the `plan`, `saved-plan` or `replan` input at this stage.

The new plan shows whether the change Terraform would make has changed since the plan stage. When Iltero Platform says a
later job applies the plan, or cannot tell which job does, the CLI compares the new plan with the checked plan by the
resources each one acts on, and records only the result. In a run that plans and applies in one job, the CLI reads the
new plan and sets it aside. The CLI never keeps or uploads the new plan. It refuses a new plan that is not newer than
the checked plan, or that was made after the pre-deploy stage started. Terraform dates a plan to the second, so the new
plan must start at least one second after the checked plan finished.

The step stops when the records directory holds no record of the unit, or when the CLI cannot answer. When the CLI
cannot answer, the job summary reads `record does not verify` or `record unreadable`. In both cases, `deploy` does not
apply that unit or any later unit.

## Unit settings

`deploy` and `preview` read a unit's settings for an environment from the unit's own `config/` folder.

- **`config/backend/<environment>.hcl`**: backend settings, which say where Terraform keeps the environment's state.
  `deploy` passes the file to `terraform init`. `preview` does not pass it to Terraform.
- **`config/<environment>.tfvars.json`**: variable values. `deploy` and `preview` pass the file to `terraform plan`.
  `deploy` also passes it to the two readings it takes for the post-verify stage, described below.

Both files are optional. But when a unit has one of them for another environment, it must also have that file for
the environment being deployed or previewed. Otherwise the unit is not set up for this environment, and Terraform does
not run for it:

- **`deploy`** stops at that unit, and does not deploy later units. The job summary's Plan cell reads
  `not set up for this environment`.
- **`preview`** fails the step. The unit's result reads `not evaluated: the unit is not set up for this environment`.

The actions choose each environment's state through its backend settings file, not through Terraform workspaces. When
the job sets `TF_WORKSPACE`, no unit is set up for the environment, with the same results.

## Units that read other units' state

Terraform's state is the data in which Terraform tracks the resources it manages. A unit that reads another unit's
Terraform state can declare the variable `enable_remote_state_dependencies` in a `.tf` file of its folder. `deploy`
and `preview` then set it in a variables file that they pass after the unit's own.

- **`deploy`** sets it to `true`, so the unit never deploys with placeholder values in place of upstream state.
- **`preview`** sets it to `false`, because it plans with no cloud credential. The unit's result in the job summary
  and the pull request comment adds `(planned without the state of the units it reads, so the result can differ after
  the merge)` to `passed` or `failed`.

## State check

`deploy` runs `iltero state check` on each unit after `terraform init` and before the plan. The check fails unless
Terraform keeps the unit's state outside its working directory, in a remote backend such as a storage bucket. The
runner's files are deleted after the job, so state kept on the runner would be lost. A failed check stops the deploy
at that unit, and the job summary's Plan cell reads `state check failed`.

`record-iac` runs the same check at the `plan` stage, before the CLI checks the plan. It reads the job's own
`TF_DATA_DIR` when it is set, so run `terraform init` with the same value. A failed check fails the step, and the
job summary's result reads `Result: state check failed.`

## State unreadable after the apply

When Terraform cannot read a unit's state after the apply, `deploy` still records the apply. It runs the post-deploy
check with `--state-unreadable` in place of `--state`. The CLI fails that check, and the job summary's Post-deploy cell
reads `failed without the state file`. Later units are not deployed, and the post-verify stage does not run.

In a job that runs Terraform itself, give `record-iac` the input `state-unreadable: true` at `post_deploy`, and leave
`state` empty. The CLI then records the apply from the apply log alone, and the step fails. The job summary's result
reads `Result: failed without the state file.`
`examples/iac/governed-own-terraform.yml` shows how.

## Re-running a failed governed Terraform run

In a governed run, `deploy` runs `pre_deploy`, the apply and `post_deploy` in one job. A job that runs Terraform
itself must do the same, because Iltero Platform accepts the `post_deploy` record only from the job that ran
`pre_deploy`. `pre_deploy` may run in a different job from `plan`.

When a governed run fails, re-run every job of the workflow run. When the plan ran in an earlier job, a re-run of only
the job that applies joins the same run if that job failed before its `post_deploy` step started. Once its
`post_deploy` step has started, Iltero Platform refuses a re-run of that job alone.

## Post-verify readings of a Terraform unit

The post-verify stage checks that a unit's deployed resources still match what the apply left. A difference is called
drift, such as a setting changed by hand. When every unit deployed, `deploy` runs the stage for each unit whose record
requires it. At the plan stage, the CLI notes in the record which later stages the change requires. In a governed run,
Iltero Platform's settings decide; otherwise `.iltero/config.yml` does. `deploy` asks the CLI with
`iltero record in-scope` whether the record requires the post-verify stage, and the job summary's details show the
CLI's answer. When the CLI cannot answer for a unit, that unit's Post-verify cell reads `record does not verify` or
`record unreadable`. `deploy` goes on with the other units, and the step then fails.

For each such unit, `deploy` takes two readings of the deployed resources. A reading is a refresh-only plan,
`terraform plan -refresh-only`: Terraform reads the deployed resources and changes nothing. `deploy` saves each
reading and never applies it. The CLI requires the readings to be at least 60 seconds apart. The second reading shows
whether a difference lasts: a resource that differs only in the first reading is listed in the record, but not as
drift. `deploy` waits one second more than 60, because its clock and Terraform's timestamps count whole seconds. It
gives the post-verify check both readings and the state file that the post-deploy check took. The CLI reads that state
only to finish the checks the plan stage left until after the apply. A unit that fails the stage does not stop the
others. The step then fails.

In a job that runs Terraform itself, give `record-iac` the same state file at `post_verify` as at `post_deploy`, with
the input `state`. In a linked project, as at the pre-deploy stage, `record-iac` runs the post-verify check and then
asks the CLI whether the unit's record requires the stage. When it does not, the CLI has checked nothing, and the
job summary reads `not required`.

The readings can hold secret values, because Terraform does not mark every secret as sensitive. `deploy` does not upload
them. Do not keep them. The record keeps no copy of them. In a governed run it keeps a fingerprint of each; in a project
not linked to Iltero Platform, it keeps none. The `readings-directory` output names their directory, as
`<unit>/first.json` and `<unit>/second.json`.

## Image deployment

`record-image` records a deployment of an image in three stages, into one record: `pre_deploy` before the deployment,
`post_deploy` after it, and `post_verify` after the rollout.

Every stage of a deployment takes `environment`. At `post_deploy` and `post_verify`, it must match the environment in
the record.

In a project linked to Iltero Platform, each stage runs in an image deploy run: a governed run that deploys one
application's image to one environment. Each stage takes `application`, and Iltero Platform finds or opens the image
deploy run of the pipeline run for that application and environment. Each stage sends its record. The run's settings
on Iltero Platform say which stages the record requires: `pre_deploy` and `post_deploy` always, and `post_verify` when
the environment's policy requires it. The run's settings also decide whether a failed or undecided assertion fails
`pre_deploy`. An undecided assertion is one the CLI had too little information to pass or fail. Because the run's
settings decide, the CLI refuses `fail-on-failed-assertions: false` at every stage of an image deploy run. The `close`
action closes the run when it is given both `application` and `environment`.

In a project not linked to Iltero Platform, `record-image` records the deployment locally (on the runner) and sends
nothing to Iltero Platform. A local check reads no approvals and does not know whether each commit was reviewed, so an
assertion that reads either is always undecided at `pre_deploy`. `post_deploy` and `post_verify` refuse
`fail-on-failed-assertions: false`.

- **`pre_deploy`** checks the image to deploy, named by its digest with no tag. It always checks that Iltero Platform
  accepted a build of the image for the environment.
  - In a project linked to Iltero Platform, record and send the build first, with the `plan` stage of `record-image`.
    Let that step finish before the deployment's `pre_deploy` starts.
  - In a project not linked to Iltero Platform, the build check is always undecided, because only Iltero Platform
    accepts a build. `pre_deploy` therefore fails unless `fail-on-failed-assertions: false` is set. With that setting,
    failed and undecided assertions do not fail the step, and the record still shows them.
- **`post_deploy`** reports the image the deployment says it deployed.
- **`post_verify`** checks that every pod of the workload runs the deployed image. The job reads the workload, its
  pods, a Deployment's ReplicaSets, and the workload again, in that order, with `kubectl get --raw`. It passes the
  files as `workload-before-pods-listing`, `pods`, `pod-owners` and `workload-after-pods-listing`, with the unique ID
  (uid) that Kubernetes gives the cluster's `kube-system` namespace as `cluster-id`. In a project linked to Iltero
  Platform, when the check passes, `record-image` asks the CLI whether the unit's record requires the stage. When it
  does not, the CLI has checked nothing, and the job summary reads `not required`. When the CLI cannot answer, the job
  summary reads `record does not verify` or `record unreadable`, and the step fails.

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
  any stage, in a project linked to Iltero Platform. On `pull_request` events, `record-iac` and `record-image` check
  locally and need none. The Iltero CLI requests the job's GitHub identity token itself. The examples also grant it
  for the AWS role the job signs in with.
- **`ILTERO_API_URL`**, the address of Iltero Platform, in a workflow that calls it. It is the only Iltero setting.
  It must be the same address as `platform.api_url` in `.iltero/config.yml`. Otherwise every CLI command that talks
  to Iltero Platform refuses to run. The job holds no Iltero secret.
- **Cloud credentials** in a job that sets `store-records: true`. The CLI keeps each record in the run's artifact
  store, the bucket that Iltero Platform names for the run, with the job's own credentials. On AWS, set them with
  `aws-actions/configure-aws-credentials` and OpenID Connect (OIDC) before the step. Grant the role only the
  permissions below, on the Amazon Simple Storage Service (S3) bucket and its key. Each resource is named by its
  Amazon Resource Name (ARN). `<prefix>` is the folder path inside the bucket that Iltero Platform gives for the run's
  artifact store, or empty when it gives none.

  | Permission | On |
  | --- | --- |
  | `s3:PutObject`, `s3:PutObjectRetention`, `s3:GetObjectRetention` | `arn:aws:s3:::BUCKET/<prefix>artifacts/<organization id>/*` |
  | `kms:GenerateDataKey` | The bucket's Key Management Service (KMS) key, restricted with the `kms:ViaService` condition to S3 in the bucket's region |

  The role, the bucket and its key must be in the same AWS account. A store to a bucket in another account fails.
- **Network access to `github.com`, `pypi.org` and `files.pythonhosted.org`** in a `deploy` job, or a `record-iac`
  job at the `plan` stage, in a project linked to Iltero Platform. The step downloads Trivy and Checkov, the scanners
  the Iltero CLI pins, in every job. Behind a proxy, set `HTTPS_PROXY`. When the proxy presents its own certificate,
  also set `SSL_CERT_FILE` or `SSL_CERT_DIR`.

`preview` needs only `contents: read`. With `registry-host` set, it also needs `id-token: write`, because
`terraform init` downloads private modules with the job's GitHub identity token. The project must then be linked to
Iltero Platform.

`comment` needs only `pull-requests: write`. It runs in its own job, after `preview`, and runs no code from the pull
request. GitHub gives a pull request from a fork or from Dependabot a read-only token, so `comment` posts nothing for
it and leaves a notice.

`preview` and `comment` run only on `pull_request` events.

The actions refuse `pull_request_target` and `workflow_run` events. `deploy` and `close` run only on `push`,
`workflow_dispatch` and `schedule` events. Use `preview` on pull requests. On `pull_request` events, `record-iac` and
`record-image` record only the `plan` stage. `record-iac` and `record-image` refuse `pull_request_review` and
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
the syntax of every shell script under `scripts/`. CI also scans the repository for secrets with TruffleHog. It also
runs the `setup`, `preview` and `record-iac` actions on a small Terraform project in `tests/e2e/stack`, which needs no
cloud and is not linked to Iltero Platform. These two checks run only in CI. See [CONTRIBUTING.md](../CONTRIBUTING.md)
for the pull request process.
