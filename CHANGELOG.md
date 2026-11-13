# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. Installs the Iltero CLI and its evaluator at pinned, checksum-verified versions.
- `setup` installs an Iltero CLI that shows whether every commit a change ships was reviewed. `iltero record verify`,
  the `README.txt` of a record package and `iltero record report` show it on a "Commit review" line. When the log of
  `terraform apply` ends with neither Terraform's counts of the changes nor an error, the CLI records the apply as cut
  short. It then settles each change from the state, as applied, failed or unknown, and never records a change as not
  attempted.
- `close` action. Closes the governed run of this pipeline run on Iltero Platform: the change run of the stack in
  `.iltero/config.yml` and an environment, the build run of an application, or the image deploy run of an application
  and an environment. The inputs given decide which run it closes:

  | Inputs given | Run closed |
  | --- | --- |
  | `environment` | The change run of the stack and that environment |
  | `application` | The build run of that application |
  | `application` and `environment` | The image deploy run of that application and environment |

  With neither, the step stops with "Give the environment input, the application input, or both." It also takes
  `working-directory` (`.` by default).
- `preview` action. Plans each unit of a pull request with no credentials and checks each plan locally. When a unit
  fails, the step fails with the CLI's exit code for the first failing unit. A unit that `preview` could not plan
  counts as exit code 1.
- `deploy` action. Plans, checks and applies each unit of a stack, and records each deployment: in a governed run when
  the project is linked to Iltero Platform, on the runner alone when it is not. Terraform's state is the data in which
  Terraform tracks the resources it manages. `deploy` stops before the plan when a unit keeps its Terraform state in
  its working directory. It applies a unit's saved plan only if the plan is unchanged since its check. Otherwise the
  unit fails with "The saved plan of unit '...' changed after it was checked, so the unit was not applied.", and the
  job summary's Apply cell reads `plan changed`. When it cannot read the saved plan, the unit fails with "The saved
  plan of unit '...' could not be read.", and the Plan cell reads `plan unreadable`. Terraform's error messages appear
  in the log in order with its other output.
- `preview`, `deploy`, `verify` and `record-iac` stop before any unit runs when the CLI lists no units: "The CLI lists
  no units in this stack, so there is nothing to check." They also stop when two units share a name: "Two units are
  named '...'. Give each unit its own name."
- Reference workflows `examples/iac/governed-deploy.yml` and `examples/iac/preview.yml`.
- `verify` action. Builds each unit's record bundle with `iltero record build` and verifies it with
  `iltero record verify`: the CLI checks that the record and the files it cites are unchanged. When a unit fails, the
  step fails with the CLI's exit code for the first failing unit. A unit with no record bundle, or whose report the
  CLI did not write, counts as exit code 1. The action accepts a `records-directory` relative to `working-directory`.
- Example `examples/iac/deploy.yml` for a project with no Iltero account.
- `comment` action. Posts the preview's result as a comment on the pull request, and updates it on each push. The
  `preview` action writes the comment and outputs its artifact name as `comment-artifact`. When `preview` stops
  before it checks every unit, the comment reads "The preview stopped before it checked every unit. See the job
  summary and the log." The comment also reads this, instead of "The preview has not finished.", when the step
  that finds the environment fails, including when the action refuses the environment's name.
- `write-report` input on `deploy`, `record-iac` and `verify`, on by default. The CLI writes a report of each unit's
  record as an HTML page, `record-report.html`, and as Markdown, `record-report.md`. The action uploads both as the
  artifact `<artifact-name>-report`, adds the Markdown to the job summary, and outputs the directory as
  `report-directory`. When the CLI does not write both files for a unit, the step fails at its end. When a unit also
  failed to deploy, `deploy` fails with that unit's exit code instead.
- `registry-host` input on `preview`. When it is set, `terraform init` downloads private modules with the job's GitHub
  identity token, and the job needs `id-token: write`. The project must be linked to Iltero Platform.
- `upload-records` input on `preview`, `false` by default. When it is `true`, the action uploads each unit's records,
  which hold a redacted copy of each plan, as the artifact named by `artifact-name`.
- `environment` input on `preview`, empty by default. When it is empty, the Iltero CLI finds the environment from the
  pull request's target branch. Set it when the target branch deploys to several environments, for example `main` to
  `staging` and then `production`. The action then checks the change against the named environment. The `setup` action
  installs an Iltero CLI that lets one branch deploy to several environments. `examples/iac/preview.yml` shows the
  input. When the input is empty and the CLI cannot choose an environment (exit code 2), the step adds the notice "When
  the target branch deploys to several environments, name one with the preview action's environment input." The step
  keeps the CLI's exit code.
- `deploy`, `preview`, `record-iac`, `verify` and `record-image` at its deployment stages refuse an environment that
  cannot name a directory or a file. Such a name contains `/`, or is `.` or `..`. The step stops with "The environment
  '...' cannot name a directory or a file. Use a name without '/' that is not '.' or '..'." An empty environment
  stops `deploy`, `record-iac` and `verify` with "The environment input is required." An environment with a line
  break, tab or other control character stops the step with "The environment input must be one line, with no tab or
  other control character." `record-image` at `plan` and `close` stop the same way on an environment with a control
  character. `record-image` also stops on such an `image`, `application` or `cluster-id`, and `close` on such an
  `application`.
- Settings for each unit, read from the unit's own `config/` folder. For an environment, `deploy` passes
  `config/backend/<environment>.hcl` to `terraform init` as `-backend-config`, and `deploy` and `preview` pass
  `config/<environment>.tfvars.json` to `terraform plan` as `-var-file`. Both files are optional.
- `record-iac` action, and the example `examples/iac/governed-own-terraform.yml`. In a job that runs Terraform itself,
  the action records one stage of one unit's change from the files that Terraform wrote: `plan`, `pre_deploy` (before
  the apply), `post_deploy` (after the apply) or `post_verify` (after `post_deploy`). It runs no Terraform. At `plan`,
  it first runs `iltero state check`, and the step fails unless Terraform keeps the unit's state outside its working
  directory. `pre_deploy` reads the `plan` stage's record from `records-directory`. `post_verify` checks that the
  deployed resources still match what the apply left. It takes the input `refresh-plans`: two readings of the deployed
  resources, one path per line, in the order they were taken. Each reading is a refresh-only plan, from
  `terraform plan -refresh-only -out=FILE` then `terraform show -json FILE`, and the second is taken at least 60 seconds
  after the first. Any other number of readings stops the step: "The refresh-plans input must name two readings, one per
  line, in the order they were taken. It names N." The example takes both readings after `post_deploy`. On
  `pull_request` events, the action records only `plan`, and stops at any other stage with "On pull request events,
  record-iac records only the plan stage, checked locally." It refuses `pull_request_target` and `workflow_run` events,
  and `pull_request_review` and `pull_request_review_comment` events: "record-iac does not run on '...' events. Run it
  on pull_request events, where it checks the plan locally." A unit name is 1 to 64 characters of lowercase letters,
  digits, `_` and `-`, and does not start with `-`. Any other `unit` stops the step before anything runs, with "Unit
  name '...' does not follow the unit-name rule."
- Example `examples/iac/own-terraform.yml` for a project with no Iltero account. Like
  `examples/iac/governed-own-terraform.yml`, it runs Terraform itself and records each stage with `record-iac`, on the
  runner. Its `pre_deploy` step runs no check, because that stage checks facts that only Iltero Platform holds. The
  step warns when the unit's record still expects the stage.
- `deploy` and `preview` install the Terraform they run, in a step of their own before they run it, at a pinned,
  checksum-verified version. Each time the action runs, it downloads the archive again and checks it against its
  pinned checksum. Both actions take this input and give these outputs:

  | Name | Kind | Meaning |
  | --- | --- | --- |
  | `terraform-version` | Input | The Terraform version to install and run, `1.16.5` by default. Only versions listed in `scripts/iac/terraform.sha256` are accepted. |
  | `terraform-version` | Output | The Terraform version installed. |
  | `terraform-path` | Output | The absolute path of the Terraform binary. |

  `setup` installs no Terraform. A job that uses `record-image` or `close` downloads none, and a job that uses
  `record-iac` installs its own.
- Post-verify stage in `deploy`. When every unit deployed, `deploy` checks that the deployed resources of each unit
  whose record expects the post-verify stage still match what the apply left. It reads each such unit back twice with
  `terraform plan -refresh-only`, with the same variable files as the plan, and never applies a reading. The second
  reading comes at least 61 seconds after the first, and the log says how long the deploy waits. It then runs
  `iltero iac check --stage post_verify` with `--minimum-interval-seconds 60`. A failed unit does not stop the others.
  The step fails with the first failing code: "The post-verify stage failed for one or more units. See the job
  summary." A reading that fails reads "Terraform could not read back unit '...'." No unit is read
  back when a unit failed to deploy. Each unit's report is written after its post-verify stage. When the CLI cannot
  say whether a unit's record expects the stage, the step fails after the other units. The job summary's Post-verify
  cell reads `exit N` (the CLI's exit code), `not in scope`, `terraform failed`, `record does not verify` or
  `record unreadable`. When a unit fails to deploy, every unit's Post-verify cell reads `not run`, because the stage
  runs only when every unit deployed.
- `readings-directory` output on `deploy`. It names the directory that holds each unit's two readings, as
  `<unit>/first.json` and `<unit>/second.json`. The readings can hold secret values. The action does not upload them,
  and they are not meant to be kept: the record keeps only their digests.
- `record-image` action, and the example `examples/image/governed-build.yml`. Its required `stage` input names the stage
  to record: `plan`, `pre_deploy`, `post_deploy` or `post_verify`. Any other value stops the step: "The stage input must
  be one of: plan pre_deploy post_deploy post_verify. It is '...'." At `plan`, in the pipeline run that built and pushed
  a container image, the action records the image with `iltero image check --stage=plan`, from the files the build and
  scanners wrote: `build-metadata`, `image-index`, `attestation`, `test-reports` and `scan-reports` (Trivy or Grype). It
  runs no build or scan. In a project linked to Iltero Platform, the check opens or joins the build run of the pipeline
  run for `application` and sends the record, and the job needs `id-token: write`. On `pull_request` events it checks
  the image locally and as advice: failed or undecided assertions do not fail the step. It refuses `pull_request_review`
  and `pull_request_review_comment` events. Its records go to a directory of their own unless `records-directory` is
  set. For an image built for several CPU architectures, `scan-reports` takes one report for each architecture. The
  example runs three jobs, in a governed build run on Iltero Platform. The first builds the image from the Git
  repository at the pushed commit, for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by
  default), and pushes it to the GitHub container registry. In a private repository, the build reads the source with the
  job's token. The build job stops unless `IMAGE_PLATFORMS` lists one or more platforms, such as `linux/amd64`,
  separated by commas with no spaces: "IMAGE_PLATFORMS must list one or more platforms, such as linux/amd64, separated
  by commas with no spaces." The second scans the pushed image by its digest, once for each architecture, with read
  access to the registry only, and keeps one Trivy report for each. The third signs in to AWS with a records role,
  records the image with every report, keeps the record and every file it cites in the build run's artifact store
  (`store-records: true`), and closes the build run.
- Example `examples/image/build.yml` for a project with no Iltero account. It builds and scans an image in three jobs,
  as `examples/image/governed-build.yml` does. The scan job keeps a full report for each architecture, then scans
  each one again and fails the workflow when any of them has a vulnerability at one of the severities in
  `FAIL_ON_SCAN_SEVERITIES`, `CRITICAL,HIGH` by default. When it is empty, the scan never fails the workflow. The scan
  job stops unless `FAIL_ON_SCAN_SEVERITIES` is empty or lists `UNKNOWN`, `LOW`, `MEDIUM`, `HIGH` or `CRITICAL`,
  separated by commas: "FAIL_ON_SCAN_SEVERITIES must be empty or list UNKNOWN, LOW, MEDIUM, HIGH or CRITICAL, separated
  by commas." The third job also runs when the scan failed the workflow after it kept the reports, so the record lists
  the findings. It checks the image as advice, records it on the runner and uploads the record as a workflow artifact.
  It sends nothing to Iltero Platform, so it needs no `application`, no `close` step and no `id-token: write`.
- Deployment stages in `record-image`, and the example `examples/image/deployment.yml`. The action records a
  deployment of an image with `iltero image check`, in three stages, into one record. `pre_deploy` checks the image to
  deploy, before the deployment. `post_deploy` reports the image the deployment says it deployed. `post_verify` checks,
  after the rollout, that every pod of the workload runs that image. Every deployment stage takes `environment`.
  `pre_deploy` and `post_deploy` also take `image`, by its digest with no tag. At `post_deploy` and `post_verify`, the
  CLI refuses an `environment` that differs from the record's. `post_verify` takes `cluster-id` and the readings
  `workload-before-pods-listing`, `pods`, `pod-owners` (for a Deployment) and `workload-after-pods-listing`. A missing
  input stops the step, for example "The environment input is required for stage post_verify." On `pull_request` events,
  the action records only `plan`, and stops at any other stage with "On pull request events, record-image records only
  the plan stage, checked locally." A deployment's records go to a directory for its environment unless
  `records-directory` is set. Each stage after `pre_deploy` reads the record from `records-directory`. The example
  deploys an image to Kubernetes with `kubectl`, in one job, with no Iltero account. It also records `post_deploy` when
  `kubectl set image` fails.
- Deployment stages of `record-image` in a project linked to Iltero Platform. Each stage runs in an image deploy run: a
  governed run that deploys one application's image to one environment. Each stage takes `application`, and Iltero
  Platform finds or opens the image deploy run of the pipeline run for that application and environment. Each stage
  sends its record, and the job needs `id-token: write`. With `store-records: true`, each stage also keeps its record in
  the run's artifact store. The run's settings on Iltero Platform decide whether a failed or undecided assertion fails
  `pre_deploy`, so the CLI refuses `advisory: true` at every stage of an image deploy run. The CLI refuses
  `application` in a project that is not linked.
- The example `examples/image/governed-deployment.yml`. It deploys an image to Kubernetes with `kubectl`, in a
  governed image deploy run on Iltero Platform, after `examples/image/governed-build.yml` recorded and sent the
  image's build. The deploy job runs in the GitHub deployment environment `production`. Each `record-image` step sets
  `store-records: true`. A second job closes the run when the deploy job succeeded.
- `advisory` input on `record-image`, `false` by default. When it is `true`, failed or undecided assertions do not fail
  the step, and the record still shows them. It applies to `plan` and `pre_deploy`, in a project with no `platform`
  section only. At `plan`, the assertion that the image was built from the verified commit is always undecided, because
  on the runner alone no server verifies the commit. At `pre_deploy`, an assertion that reads approvals, or whether
  each commit the change ships was reviewed, is always undecided, because a check on the runner alone reads neither.
  `pre_deploy` always checks that Iltero Platform accepted a build of the image for the environment. Only Iltero
  Platform accepts a build, so in a project with no `platform` section, `pre_deploy` fails unless `advisory` is
  `true`. Any value other than `true` or `false` stops the step: "The advisory input must be true or false, not
  '...'." `examples/image/build.yml` sets it to `true` at `plan`, and `examples/image/deployment.yml` at `pre_deploy`.
- `store-records` input on `deploy`, `record-iac` and `record-image`, `false` by default. When it is `true` in a project
  linked to Iltero Platform, the CLI also keeps each record and every file it cites in the run's artifact store: the
  bucket that Iltero Platform names for the run. The CLI writes there with the job's own cloud credentials. A failed
  store fails the step. The CLI refuses `true` in a project that is not linked. Any value other than `true` or `false`
  stops the step: "The store-records input must be true or false, not '...'." On `pull_request` events, `record-iac` and
  `record-image` do not use it. The example `examples/iac/governed-own-terraform.yml` sets it to `true` on every
  `record-iac` step.
- `setup` installs the Iltero CLI's AWS client packages, which the CLI uses to keep records in an artifact store on
  AWS.
- The actions run their Python helpers isolated from the working directory, so a Python file in the checked-out
  repository cannot replace a module they import.
- In a project linked to Iltero Platform, the plan stage's check opens a change run for the pipeline run, stack and
  environment, and each later stage joins it. `deploy` and `record-iac` send each stage's record. No separate step
  opens a run, and no run id passes between jobs.
- `preview` and `record-iac` on a pull request check each plan locally, also for a project linked to Iltero Platform.
  The check never contacts Iltero Platform, and its record is not evidence of the change. It checks the project's own
  assertions, while the checks after the merge use the assertions that Iltero Platform sets. A linked project's
  `preview` needs no `ILTERO_API_URL` and, unless `registry-host` is set, no `id-token: write`.
- Pre-deploy stage in a project with no `platform` section. In such a project, list `pre_deploy` under
  `stages.out_of_scope` in `.iltero/config.yml`. `deploy` and `record-iac` do not run the pre-deploy stage there,
  because it checks facts that only Iltero Platform holds. They ask the CLI instead whether the unit's record from the
  plan stage expects the pre-deploy stage. When the records directory holds no record of the unit, the step stops with
  "The records directory holds no record of unit '...'." `record-iac` adds "Run the plan stage first. In another job,
  download the plan job's records artifact and pass its directory as records-directory." When the CLI cannot say
  whether the record expects the stage, the step stops. `deploy` does not apply the unit then, and its job summary's
  Pre-deploy cell reads `no record`, `record does not verify` or `record unreadable`. When the record expects the
  stage, the cell reads `not run`, and the step warns: "The record of unit '...' expects the pre-deploy stage, which a
  project with no platform section does not run. List pre_deploy under stages.out_of_scope in .iltero/config.yml."
  Otherwise the cell reads `not in scope`. `record-iac` also adds the notice "A project with no platform section does
  not run the pre-deploy stage. Nothing was checked."
- Default artifact names. When `artifact-name` is empty, `deploy`, `verify`, `record-iac` and `record-image` name
  their artifact as follows. The artifact of `verify` holds record bundles, and the others hold records.

  | Action | Default artifact name |
  | --- | --- |
  | `deploy` | `iltero-deploy-<environment>` |
  | `verify` | `iltero-record-bundles-<environment>` |
  | `record-iac` | `iltero-records-<environment>-<unit>` |
  | `record-image`, `plan` stage | `iltero-image-records-<unit>` |
  | `record-image`, deployment stages | `iltero-image-deployment-records-<environment>-<unit>` |

  When the default name is not a valid artifact name, the step stops with "The default artifact name '...' is not a
  valid artifact name. Set the artifact-name input." `deploy` and `verify` check a given `artifact-name` before
  anything runs, and output the name as `artifact-name`. `verify` requires `environment`: the environment the deploy
  action deployed. Its job summary is headed `Iltero record bundles: <environment>`. By default, `deploy`,
  `record-iac` and the deployment stages of `record-image` keep each environment's records in a directory of its own
  under the runner's temporary directory. `deploy`, `verify` and `record-iac` keep each environment's reports apart in
  the same way.
- Artifact retention. The records and report artifacts of `deploy`, `verify`, `record-iac` and `record-image` follow
  the repository's or organization's artifact retention setting. `preview` keeps its records artifact for 30 days and
  its comment artifact for 1 day.
- `record-iac` and `record-image` warn when the records directory they upload is empty.
- The `close` jobs of `examples/iac/governed-deploy.yml` and `examples/iac/governed-own-terraform.yml` close the run
  when the deploy job succeeded. A run whose deploy failed or was cancelled stays open, so a re-run of the failed job
  joins it.
- The job summaries of `deploy`, `preview`, `verify`, `record-iac` and `record-image` stay within GitHub's size
  limit. When the CLI's output for a unit or stage would push a summary past it, the summary reads "The output of
  ... is too long for the job summary. It is in the log." in its place, where `...` names the unit or stage. The limit
  counts the output as it appears in the summary, after escaping. When a unit's report would push the summary of
  `deploy`, `verify` or `record-iac` past the limit, the summary reads "The report of unit ... is too long for the job
  summary. It is in the report artifact." in its place. The summaries escape the output in one pass, so a large plan
  does not slow them.
- After a failed unit, the job summary of `deploy` lists every later unit with `not run` in each of its stage columns.
  The failed unit reads `not run` in each stage it did not reach.
- `deploy`, `verify`, `record-iac` and `record-image` keep a given `artifact-name` that looks like an option, such as
  `-n`, `-e` or `-E`, and use it for the `artifact-name` output and the upload.
- `record-iac`, `record-image` and `verify` take a relative `records-directory` that looks like an option, such as
  `--`, `-` or `-e`, as a directory under `working-directory`. The `records-directory` output gives its absolute path.
  `verify` refuses an empty `records-directory` with "The records directory is empty. Pass the deploy action's
  records-directory.", and its message for a missing directory names the directory as the user gave it.
- `deploy`, `preview`, `record-iac` and `verify` refuse a unit whose directory starts with `-` before any unit runs:
  "Unit '...' has a directory that starts with '-': '...'. Rename the directory."
- When `deploy` cannot get a registry token for a unit, that unit's Plan cell reads `registry token failed`. The step
  still writes its job summary, and every later unit reads `not run`. `deploy` refuses an invalid `registry-host`
  before any unit runs, as `preview` does: "Invalid registry host '...'."
- When `record-image` checks a stage as advice, on `pull_request` events or with `advisory: true`, and the CLI exits
  with code 0, its job summary reads "Result: exit 0, checked as advice: failed or undecided assertions do not fail the
  step." A non-zero exit code shows alone: "Result: exit N."
- `deploy` and `preview` read Terraform's whole version output before they check the version, so the check does not
  fail at random.
  When the installed Terraform does not run, the step stops with "The installed Terraform did not run."
- `preview` and `verify` clear each unit's work directory before the unit runs, so no output of an earlier step in
  the same job shows in the summary.
- `setup` asks the Iltero CLI which evaluator to download, with `iltero evaluator pin --platform <platform>`. The CLI
  answers with the evaluator pin: the evaluator's release, the name of the file to download and the file's SHA-256
  digest, which `setup` checks the download against. When the CLI cannot answer, the step stops with "The Iltero CLI
  could not report the evaluator pin for ...", where `...` is `linux-x86_64` or `linux-aarch64`. An answer that is
  not one line of three well-formed fields stops the step with "The evaluator pin the Iltero CLI reports is malformed."
- In a project with no platform section, `deploy` and `record-iac` ask the CLI whether a unit's record expects the
  pre-deploy stage, with `iltero record in-scope`. After every unit deploys, `deploy` also asks it, in every project,
  whether the record expects the post-verify stage. The CLI verifies the record before it answers. When the CLI cannot
  answer, the step shows "The CLI could not say whether the record of unit '...' expects the pre-deploy stage (exit
  N).", or the same message with "post-verify". At the pre-deploy stage, the unit fails with the CLI's exit code. At
  the post-verify stage, `deploy` records the failure for that unit and goes on with the other units. The step then
  fails with the first non-zero exit code of any unit's post-verify stage. The job summary reads `record does not
  verify` for exit code 9, and `record unreadable` for any other code. The job summary's details show the CLI's
  answer, labelled `in-scope-pre-deploy` or `in-scope-post-verify`.
- `deploy` records the apply even when Terraform cannot read the state after it. The step shows "Terraform could not
  read the state of unit '...' after the apply." It runs the post-deploy check with `--state-unreadable` in place of
  `--state`, and the job summary's Post-deploy cell reads `exit N, state not read`. The unit fails with the apply's exit
  code when the apply failed, and otherwise with the CLI's exit code. Later units are not deployed, and the post-verify
  stage does not run.
- `state-unreadable` input on `record-iac`, `false` by default, for the `post_deploy` stage. Set it to `true` when
  Terraform could not read the state after the apply, and leave `state` empty. The CLI then records the apply from the
  apply log alone, and the step fails. The job summary's result reads `exit N, state not read`. `state` is required at
  `post_deploy` unless `state-unreadable` is `true`. When both are given, the step stops with "Give either the state
  input or state-unreadable: true, not both." At any other stage, `true` stops the step with "The state-unreadable
  input applies only to the post_deploy stage." Any value other than `true` or `false` stops it with "The
  state-unreadable input must be true or false, not '...'." In `examples/iac/governed-own-terraform.yml`, the
  `post_deploy` step passes `state` when the step that reads the state succeeded, and sets `state-unreadable` when that
  step failed.
