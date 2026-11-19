# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. It installs the Iltero command-line tool (CLI), the CLI's AWS client packages, and its evaluator,
  the program that runs the assertions, at pinned, checksum-verified versions. It installs no Terraform. It asks the
  CLI which evaluator release to download, with `iltero evaluator pin --platform <platform>`, and checks the download
  against the SHA-256 digest the CLI gives. When the CLI cannot answer, the step stops with "The Iltero CLI could not
  say which evaluator release to download for ... Its message above says why.", where `...` is `linux-x86_64` or
  `linux-aarch64`. Any other answer than one line with a version, a file name and a digest stops the step with "The
  Iltero CLI did not name the evaluator release to download as one line with a version, a file name and a SHA-256
  digest."
- New file format in the installed CLI. Every record the CLI writes, and every assertion file it reads, starts with
  its format version, `apiVersion: iltero.com/v1`, and its type, `kind`. `.iltero/config.yml` keeps `version: 1`. A
  project's own assertion file starts with `kind: TechnicalAssertion`. An assertion's identifier has five parts in a
  fixed order: who wrote it, the kind of change, what it is about, the provider and service, and the check. For
  example, `ILT.AWS.S3.PUBLIC_ACCESS_BLOCKED` is now `ILT.IAC.RESOURCE.AWS.S3.PUBLIC_ACCESS_BLOCKED`. A project's own
  identifiers follow the same order and must not start with `ILT`. The CLI stops on a file that breaks either rule,
  and the step fails.
- Four new settings under `assertions` in `.iltero/config.yml`, which `iltero init` writes: `scanner_check_mapping`,
  `required_scanners`, `local_exceptions` and `values_known_after_deployment`. Some values in a plan are known only
  after the apply, such as an identifier the cloud assigns. With `values_known_after_deployment: postpone`, the plan
  check leaves a check that reads such a value to the post-verify stage, when the record requires that stage. The
  post-verify stage decides it from the state file that the post-deploy stage checked. With `block`, the plan check
  stops on it, and the step fails. A governed run postpones nothing.
- `iac_tool` setting in `.iltero/config.yml`: the infrastructure-as-code tool whose files the project's IaC checks
  read. The installed CLI reads only `terraform`. `iltero init --iac-tool` writes it. A project that checks only images
  leaves it out. The CLI refuses an IaC check in a project whose configuration file names no tool, and the step fails.
- A repository can hold several projects, each in its own folder with its own `.iltero/config.yml`. Give each action
  that folder, relative to the repository root, as `project-directory`. The folder must be committed. The CLI refuses a
  project folder that the commit of its repository does not hold as a folder, and the step fails.
- Starter assertions are the assertions shipped with Iltero. They apply only in a run that Iltero Platform did not
  open, such as a preview. With them on, the plan check reports that something was not checked when the plan holds no
  resource for one of them. It reports the same when the plan holds a CloudTrail, AWS Config or IAM policy resource
  and no scanner report decides it. The step then fails.
- The record shows whether every commit a change ships was reviewed, on a "Commit review" line of
  `iltero record verify`, `iltero record report` and the `README.txt` of a record bundle. When the log of
  `terraform apply` ends with neither Terraform's counts of the changes nor an error, the CLI records the apply as cut
  short. It settles each change from the state as applied, failed or unknown, never as not attempted.
- `close` action. It closes the governed run of this pipeline run on Iltero Platform. The inputs given decide which
  run it closes:

  | Inputs given | Run closed |
  | --- | --- |
  | `environment` | The change run of the stack in `.iltero/config.yml` and that environment |
  | `application` | The build run of that application |
  | `application` and `environment` | The image deploy run of that application and environment |

  With neither, the step stops with "Give the environment input, the application input, or both." It also takes
  `project-directory` (`.` by default).
- `preview` action. It plans each unit of a pull request with no credentials and checks each plan locally. When a unit
  fails its check, or `preview` could not plan it, the step fails.
- `deploy` action. It plans, checks and applies each unit of a stack, and records each deployment: in a governed run
  when the project is linked to Iltero Platform, locally (on the runner) when it is not. Terraform's state is the data
  in which Terraform tracks the resources it manages. `deploy` stops before the plan when a unit keeps its state in
  its working directory. It applies a saved plan only if the plan is unchanged since its check. Otherwise the unit
  fails with "The saved plan of unit '...' changed after it was checked, so the unit was not applied.", and the job
  summary's Apply cell reads `plan changed`. An unreadable saved plan fails the unit with "The saved plan of unit
  '...' could not be read.", and the Plan cell reads `plan unreadable`. Terraform's error messages appear in the log
  in order with its other output. The stage cells read `passed` or `failed`, and the Apply cell reads `applied` or
  `apply failed`. Post-deploy adds "without the state file" when Terraform could not read the state.
- `preview`, `deploy`, `verify` and `record-iac` stop before any unit runs when the CLI lists no units: "The CLI lists
  no units in this stack, so there is nothing to check." They also stop when two units share a name: "Two units are
  named '...'. Give each unit its own name."
- Reference workflows `examples/iac/governed-deploy.yml` and `examples/iac/preview.yml`.
- `verify` action. It builds each unit's record bundle with `iltero record build`, a folder that holds the record and
  every file it cites. It then checks with `iltero record verify` that the record and its files are unchanged. The
  step fails when a unit's bundle does not build or does not verify, when a unit has no record bundle or more than
  one, or when the CLI did not write a unit's report. `records-directory` may be relative to `project-directory`. The
  optional `unit` input names one unit, as `iltero units list` prints it. The action then builds, verifies and uploads
  only that unit's bundle, and keeps its reports in a directory of their own. A name that breaks the unit-name rule
  stops the step with "The unit name '...' is not valid. A unit name is 1 to 64 lowercase letters, digits, '_' or '-',
  and does not start with '-'." A unit the stack does not list stops it with "The stack has no unit '...'. Use a name
  that 'iltero units list' prints." Both stop the step before it writes any output, so it uploads nothing.
- Example `examples/iac/deploy.yml` for a project not linked to Iltero Platform.
- `comment` action. It posts the preview's result as a comment on the pull request, and updates it on each push. The
  `preview` action writes the comment and outputs its artifact name as `comment-artifact`. When the downloaded
  artifact holds no comment, the step stops with "The comment artifact holds no comment file. Set artifact-name to the
  comment-artifact output of the preview action." When `preview` stops before it checks every unit, or when the step
  that finds the environment fails, the comment reads "The preview stopped before it checked every unit. See the job
  summary and the log." `comment` finds its own comment also when the pull request holds a comment with no author or
  no text.
- The preview comment stays within GitHub's size limit for a comment. When the CLI's output would push the comment past
  it, the comment shows the result table and "The CLI's output is too long for a comment." When the result table
  alone is too long, the comment shows the result's heading, which names the environment, and "The result is too
  long for a comment." Each comment ends with the commit and a link to the job summary.
- `write-report` input on `deploy`, `record-iac` and `verify`, on by default. The CLI writes a report of each unit's
  record as an HTML page, `record-report.html`, and as Markdown, `record-report.md`. The action uploads both as the
  artifact `<artifact-name>-report`, adds the Markdown to the job summary, and outputs the directory as
  `report-directory`. When the CLI does not write both files for a unit, the step fails at its end. When a unit also
  failed to deploy, the step reports the deploy failure.
- `registry-host` input on `preview`. When it is set, `terraform init` downloads private modules with the job's GitHub
  identity token, and the job needs `id-token: write`. In a project not linked to Iltero Platform, the step stops with
  "This project is not linked to the server, so it cannot use the Iltero module registry. Add a platform section to
  .iltero/config.yml, or leave registry-host empty."
- `upload-records` input on `preview`, `false` by default. When it is `true`, the action uploads each unit's records,
  which hold a redacted copy of each plan, as the artifact named by `artifact-name`.
- `environment` input on `preview`, empty by default. When it is empty, the CLI finds the environment from the pull
  request's target branch. Set it when the target branch deploys to several environments, for example `main` to
  `staging` and then `production`. `examples/iac/preview.yml` shows the input. When the input is empty and the CLI
  cannot choose an environment, the step fails and adds the notice "When the target branch deploys to several
  environments, name one with the preview action's environment input."
- `deploy`, `preview`, `record-iac`, `verify` and the deployment stages of `record-image` refuse an environment that
  cannot name a directory or a file: "The environment '...' cannot name a directory or a file. Use only letters,
  digits, '.', '_' and '-', and not '.' or '..' alone." An empty environment stops `deploy`, `record-iac` and `verify`
  with "The environment input is required." An environment with a line break, tab or other control character stops the
  step with "The environment input must be one line, with no tab or other control character." `record-image` at `plan`
  and `close` stop the same way. `record-image` also stops on such an `image`, `application` or `cluster-id`, and
  `close` on such an `application`.
- Settings for each unit, read from the unit's own `config/` folder. For an environment, `deploy` passes
  `config/backend/<environment>.hcl` to `terraform init` as `-backend-config`, and `deploy` and `preview` pass
  `config/<environment>.tfvars.json` to `terraform plan` as `-var-file`. Each file is optional, unless the unit has a
  file of the same kind for another environment.
- `record-iac` action, and the example `examples/iac/governed-own-terraform.yml`. In a job that runs Terraform itself,
  the action records one stage of one unit's change from the files Terraform wrote: `plan`, `pre_deploy` (before the
  apply), `post_deploy` (after the apply) or `post_verify` (after `post_deploy`). It runs no Terraform. At `plan`, it
  first runs `iltero state check`, which fails the step unless Terraform keeps the unit's state outside its working
  directory. `pre_deploy` reads the `plan` stage's record from `records-directory`. `post_verify` checks that the
  deployed resources still match what the apply left. It takes the input `refresh-only-plans`: two readings of the
  deployed resources, as JSON, one path per line, in the order they were taken. A reading is a refresh-only plan, from
  `terraform plan -refresh-only -out=FILE` then `terraform show -json FILE`. Take the second at least 60 seconds after
  the first. The action trims the spaces around each line. It stops the step on:

  | Input | Message |
  | --- | --- |
  | Any number of readings other than two | "The refresh-only-plans input must name two refresh-only plans, one per line, in the order they were taken. It names N." |
  | A path that is not a file | "The refresh-only-plans input names no file: '...'." |
  | A path with a tab or other control character | "The refresh-only-plans input must be one line, with no tab or other control character." |
  | No `state` at `post_verify` | "The state input is required for stage post_verify." |
  | A `unit` that breaks the unit-name rule | "The unit name '...' is not valid. A unit name is 1 to 64 lowercase letters, digits, '_' or '-', and does not start with '-'." |

  `post_verify` takes the same `state` file that `post_deploy` took, so the CLI can finish the checks the plan stage
  left until after the apply. On `pull_request` events, the action records only `plan`. Any other stage stops with "On
  pull request events, record-iac records only the plan stage, checked locally. Record the other stages after the
  merge, for example on push events." It refuses `pull_request_target` and `workflow_run` events with "Iltero actions
  do not run on '...' events. Run them on pull_request events for a pull request, or after the merge."
  It refuses `pull_request_review` and `pull_request_review_comment` events with "record-iac does not run on ...
  events. Run it on pull_request events, where it checks the plan locally."
- `scan-reports` input of `record-iac`, for the `plan` stage. It takes the reports of scanners that checked the plan
  as JSON, the file the `plan` input names, one per line: the scanner (`checkov` or `trivy`), a space, then the path
  of its JSON report, at most one report for each scanner. The action trims the spaces around each line, skips blank
  lines, and passes each report to the CLI in the order given. A line that names another scanner or no report stops
  the step with "Each line of the scan-reports input must be a scanner (checkov trivy), a space and the report's path.
  One line is '...'." A report that is not a file stops it with "The scan-reports input names no file: '...'." At any
  other stage, the input stops the step with "Stage ... does not read the scan-reports input. Remove it from this
  step." The input is for a project not linked to Iltero Platform, or for `pull_request` events. In a linked project,
  on any other event, the CLI refuses the reports and the step fails: the run's settings on Iltero Platform decide
  which checks run.
- `examples/iac/own-terraform.yml` scans the plan with Checkov 3.3.8 and Trivy 0.72.0, scanners that check a plan for
  security problems, and gives both reports to the plan stage through `scan-reports`. Each scanner runs in its
  container image, named by its digest, with no network and only the plan mounted, so it gets none of the job's files
  or cloud credentials. Neither scan stops the job on a finding, since the CLI gives the verdict. Every example uses
  the same Trivy release, 0.72.0.
- Example `examples/iac/own-terraform.yml` for a project not linked to Iltero Platform. It runs Terraform itself and
  records each stage with `record-iac`, on the runner. Its `pre_deploy` step runs no check, because that stage checks
  facts that only Iltero Platform holds. The step fails when the unit's record still requires the stage. A last step
  builds and checks the unit's record bundle with `verify`. It runs unless the job was cancelled, as long as the plan
  stage wrote the records directory.
- `tool` input on `deploy` and `preview`: the infrastructure-as-code (IaC) tool the stack uses, `terraform` by default
  and the only supported tool. Any other value stops the step: "The tool input must be one of: terraform. It is
  '...'." Messages and job summary cells name the tool, for example `Terraform failed`.
- `deploy` and `preview` install the IaC tool they run, in a step named "Install the IaC tool", at a pinned,
  checksum-verified version. Each run downloads the archive again and checks it against its pinned checksum. Both
  actions take this input and give these outputs:

  | Name | Kind | Meaning |
  | --- | --- | --- |
  | `tool-version` | Input | The version of the tool to install and run. When it is empty, as it is by default, the action installs the version it pins for the tool: Terraform 1.16.5. The action accepts only the versions that `scripts/iac/tools/terraform/checksums.sha256` lists. |
  | `tool-version` | Output | The version of the tool installed. |
  | `tool-path` | Output | The absolute path of the tool's binary. |

  A version the action does not pin stops the step: "Terraform X.Y.Z is not a version this action can install. It can
  install: 1.16.5." When the installed Terraform does not run, the step stops with "The installed Terraform did not
  run." A job that uses `record-image` or `close` downloads no tool, and a job that uses `record-iac` installs its
  own.
- Post-verify stage in `deploy`. When every unit deployed, `deploy` checks that each unit whose record requires the
  stage still matches what the apply left. It asks the CLI with `iltero record in-scope`, which verifies the record
  before it answers. For each such unit, it takes two readings with `terraform plan -refresh-only`, with the plan's
  variable files, and never applies them. The second reading comes at least 61 seconds after the first (the CLI
  requires 60, and clocks count whole seconds), and the log says how long the deploy waits. It then runs
  `iltero iac check --stage post_verify` with `--minimum-interval-seconds 60` and the state file the post-deploy stage
  checked. Each unit's report is written after its post-verify stage. A failed unit does not stop the others, and the
  step then fails with "The post-verify stage failed for one or more units. See the job summary." A failed reading
  shows "Terraform could not read the deployed resources of unit '...'." When the CLI cannot say whether a record
  requires the stage, the step shows "The CLI could not say whether the record of unit '...' requires the post-verify
  stage. See the CLI's output in the log." The Post-verify cell reads `passed`, `failed`, `not required`,
  `Terraform failed`, `record does not verify` or `record unreadable`. When a unit failed to deploy, every unit's
  Post-verify cell reads `not run`.
- `readings-directory` output on `deploy`. It names the directory that holds each unit's two readings, as
  `<unit>/first.json` and `<unit>/second.json`. The readings can hold secret values. The action does not upload them.
  Do not keep them: the record keeps only their digests.
- `record-image` action, and the example `examples/image/governed-build.yml`. The required `stage` input names the
  stage to record: `plan`, `pre_deploy`, `post_deploy` or `post_verify`. Any other value stops the step: "The stage
  input must be one of: plan pre_deploy post_deploy post_verify. It is '...'." At `plan`, in the pipeline run that
  built and pushed a container image, the action checks the image with `iltero image check --stage=plan`, from the
  files the build and the scanners wrote: `build-metadata`, `image-index`, `attestation`, `test-reports` and
  `scan-reports` (Trivy or Grype). For an image built for several CPU architectures, `scan-reports` takes one report
  for each. It runs no build or scan. In a project linked to Iltero Platform, the check opens or joins the build run
  of the pipeline run for `application` and sends the record, and the job needs `id-token: write`. On `pull_request`
  events it checks the image locally and as advice: failed or undecided assertions do not fail the step. An undecided
  assertion is one the CLI had too little information to pass or fail. It refuses `pull_request_review` and
  `pull_request_review_comment` events. Its records go to a directory of their own unless `records-directory` is set.
  The example runs three jobs in a governed build run. The first builds the image from the Git repository at the
  pushed commit, for each CPU architecture in `IMAGE_PLATFORMS` (`linux/amd64,linux/arm64` by default), and pushes it
  to the GitHub container registry. It stops unless `IMAGE_PLATFORMS` lists one or more platforms: "IMAGE_PLATFORMS
  must list one or more platforms, such as linux/amd64, separated by commas with no spaces." The second reads the
  pushed image's index (the list of the image's architectures, each with its own digest), and scans the image of each
  architecture by its digest, so each report names exactly the image it scanned. It has read access to the registry
  only. It stops when the index the build job kept does not match the pushed image's digest: "The index the build job
  kept does not match the digest of the pushed image." It stops unless the index lists exactly one image for each
  architecture: "The image's index must list exactly one image for ...". The third signs in to AWS with a records
  role, records the image with every report, keeps the record in the build run's artifact store
  (`store-records: true`), and closes the build run.
- Example `examples/image/build.yml` for a project not linked to Iltero Platform. It builds and scans an image in
  three jobs, as `examples/image/governed-build.yml` does. The scan job fails the workflow when any architecture has a
  vulnerability at one of the severities in `FAIL_ON_SCAN_SEVERITIES`, `CRITICAL,HIGH` by default, and never when it
  is empty. Any other value stops the job: "FAIL_ON_SCAN_SEVERITIES must be empty or list UNKNOWN, LOW, MEDIUM, HIGH
  or CRITICAL, separated by commas." The third job also runs when the scan failed the workflow after it kept the
  reports, so the record lists the findings. It checks the image as advice and uploads the record as a workflow
  artifact. It needs no `application`, no `close` step and no `id-token: write`.
- Deployment stages in `record-image`, and the example `examples/image/deployment.yml`. The action records a
  deployment of an image in three stages, into one record. `pre_deploy` checks the image to deploy. `post_deploy`
  reports the image the deployment says it deployed. `post_verify` checks, after the rollout, that every pod of the
  workload runs that image. Every deployment stage takes `environment`, and the CLI refuses one that differs from the
  record's at `post_deploy` and `post_verify`. `pre_deploy` and `post_deploy` also take `image`, by its digest with no
  tag. `post_verify` takes `cluster-id`, `workload-before-pods-listing`, `pods`, `pod-owners` (for a Deployment) and
  `workload-after-pods-listing`. A missing input stops the step, for example "The environment input is required for
  stage post_verify." On `pull_request` events, any stage but `plan` stops with "On pull request events, record-image
  records only the plan stage, checked locally. Record the other stages after the merge, for example on push
  events." A deployment's records go to a directory for its environment unless `records-directory` is set. Each stage
  after `pre_deploy` reads the record from `records-directory`. The example deploys an image to Kubernetes with
  `kubectl`, in one job, and also records `post_deploy` when `kubectl set image` fails.
- Deployment stages of `record-image` in a project linked to Iltero Platform. Each stage runs in an image deploy run:
  a governed run that deploys one application's image to one environment. Each stage takes `application`, sends its
  record, and needs `id-token: write`. The run's settings decide whether a failed or undecided assertion fails
  `pre_deploy`, so the CLI refuses `fail-on-failed-assertions: false` at every stage of an image deploy run. The CLI
  refuses `application` in a project not linked to Iltero Platform.
- The example `examples/image/governed-deployment.yml`. It deploys an image to Kubernetes with `kubectl` in an image
  deploy run, after `examples/image/governed-build.yml` recorded the image's build. The deploy job runs in the GitHub
  deployment environment `production`. Each `record-image` step sets `store-records: true`. A second job closes the
  run when the deploy job succeeded.
- `fail-on-failed-assertions` input on `record-image`, `true` by default. When it is `false`, failed or undecided
  assertions do not fail the step, and the record still shows them. `false` applies only to `plan` and `pre_deploy`,
  in a project not linked to Iltero Platform. There, at `plan`, the assertion that the image was built from the
  verified commit is always undecided, because no server verifies the commit. At `pre_deploy`, an assertion that reads
  approvals, or whether each commit was reviewed, is always undecided. `pre_deploy` always checks that Iltero Platform
  accepted a build of the image for the environment, so in such a project it fails unless the input is `false`. Any
  value other than `true` or `false` stops the step: "The fail-on-failed-assertions input must be true or false, not
  '...'." `examples/image/build.yml` sets it to `false` at `plan`, and `examples/image/deployment.yml` at
  `pre_deploy`.
- `store-records` input on `deploy`, `record-iac` and `record-image`, `false` by default. When it is `true` in a
  project linked to Iltero Platform, the CLI also keeps each record and every file it cites in the run's artifact
  store, the bucket that Iltero Platform names for the run, with the job's own cloud credentials. A failed store fails
  the step. The CLI refuses `true` in a project not linked to Iltero Platform. Any value other than `true` or `false`
  stops the step: "The store-records input must be true or false, not '...'." On `pull_request` events, `record-iac`
  and `record-image` ignore it. `examples/iac/governed-own-terraform.yml` sets it on every `record-iac` step.
- The actions run their Python helpers isolated from the working directory.
- In a project linked to Iltero Platform, the plan stage's check opens a change run for the pipeline run, stack and
  environment, and each later stage joins it. `deploy` and `record-iac` send each stage's record. No separate step
  opens a run, and no run ID passes between jobs.
- On a pull request, `preview` and `record-iac` check each plan locally, also in a project linked to Iltero Platform.
  The check never contacts Iltero Platform, and its record is not evidence of the change. It checks the project's own
  assertions, while the checks after the merge use the assertions that Iltero Platform sets. A linked project's
  `preview` needs no `ILTERO_API_URL` and, unless `registry-host` is set, no `id-token: write`.
- Pre-deploy stage in a project not linked to Iltero Platform. List `pre_deploy` under `stages.out_of_scope` in
  `.iltero/config.yml`: `deploy` and `record-iac` do not run the stage there, because it checks facts that only Iltero
  Platform holds. They ask the CLI with `iltero record in-scope` whether the unit's plan-stage record requires it.

  | When | Result |
  | --- | --- |
  | The records directory holds no record of the unit | The step stops with "The records directory holds no record of unit '...'." `record-iac` adds "Run the plan stage first. In another job, download the plan job's records artifact and pass its directory as records-directory." |
  | The CLI cannot answer | The step stops with "The CLI could not say whether the record of unit '...' requires the pre-deploy stage. See the CLI's output in the log." `deploy` does not apply the unit, and its Pre-deploy cell reads `no record`, `record does not verify` or `record unreadable`. |
  | The record requires the stage | The step fails with "The record of unit '...' requires the pre-deploy stage, which only a project linked to the server can run. List pre_deploy under stages.out_of_scope in .iltero/config.yml." `deploy` fails before the apply, its Pre-deploy cell reads `required, needs the server`, and later units are not deployed. `record-iac` shows "Result: required, needs the server." |
  | The record does not require the stage | The cell reads `not required`. `record-iac` adds the notice "A project not linked to the server does not run the pre-deploy stage, and this unit's record does not require it. Nothing was checked." |

- The job summary's details show the CLI's own output for each step, under titles such as `network: state check`,
  `network: plan` and `network: is the pre-deploy stage required?`.
- Artifact names. The artifact of `verify` holds record bundles, and the artifacts of `deploy`, `record-iac` and
  `record-image` hold records. Every name ends with `-attempt-<attempt>`, where `<attempt>` is the attempt number of
  the pipeline run (on GitHub, the workflow run), so a re-run keeps the artifacts of earlier attempts. When
  `artifact-name` is set, the name is `<artifact-name>-attempt-<attempt>`. When it is empty, the name is the default
  below. The report artifact is named `<artifact name>-report`.

  | Action | Default artifact name |
  | --- | --- |
  | `deploy` | `iltero-deploy-<environment>-attempt-<attempt>` |
  | `verify` | `iltero-record-bundles-<environment>-attempt-<attempt>` |
  | `verify`, with `unit` set | `iltero-record-bundles-<environment>-<unit>-attempt-<attempt>` |
  | `record-iac` | `iltero-records-<environment>-<unit>-attempt-<attempt>` |
  | `record-image`, `plan` stage | `iltero-image-records-<unit>-attempt-<attempt>` |
  | `record-image`, deployment stages | `iltero-image-deployment-records-<environment>-<unit>-attempt-<attempt>` |

  An invalid name stops the step with "The artifact name '...' is not a valid artifact name. Set the artifact-name
  input." `deploy` and `verify` check a given `artifact-name` before anything runs. Each action outputs the full name
  as `artifact-name`. A name that looks like an option, such as `-n`, is kept as given. `verify` requires
  `environment`, and its job summary is headed `Iltero record bundles: <environment>`. By default, `deploy`,
  `record-iac` and the deployment stages of `record-image` keep each environment's records, and `deploy`, `verify` and
  `record-iac` each environment's reports, in a directory of their own under the runner's temporary directory.
- `retention-days` input on `deploy`, `verify`, `record-iac` and `record-image`: the number of days GitHub keeps the
  artifacts the action uploads, a whole number of 1 or more. When it is empty, as it is by default, the repository's
  artifact retention setting applies. Any other value stops the step with "The retention-days input must be empty or a
  whole number of days of 1 or more. It is '...'." `preview` keeps its records artifact for 30 days and its comment
  artifact for 1 day.
- `record-iac` and `record-image` warn when the records directory they upload is empty.
- The `close` jobs of `examples/iac/governed-deploy.yml` and `examples/iac/governed-own-terraform.yml` close the run
  when the deploy job succeeded. A run whose deploy failed or was cancelled stays open, so a re-run of the failed job
  joins it.
- The job summaries stay within GitHub's size limit. When the CLI's output for a unit or stage would push a summary
  past it, the summary reads "The output of ... is too long for the job summary. It is in the log." in its place. When
  a unit's report would, the summary reads "The report of unit ... is too long for the job summary. It is in the
  report artifact."
- `record-iac`, `record-image` and `verify` take a relative `records-directory` as a directory under
  `project-directory`, also one that looks like an option, such as `-`. The `records-directory` output of `record-iac`
  and `record-image` gives its absolute path. `verify` refuses an empty `records-directory` with "The records
  directory is empty. Pass the records-directory output of the deploy or record-iac action.", and a missing one with
  "The records directory '...' does not exist. Pass the records-directory output of the deploy or record-iac action."
- `deploy`, `preview`, `record-iac` and `verify` refuse a unit whose directory starts with `-` before any unit runs:
  "Unit '...' has a directory that starts with '-': '...'. Rename the directory."
- When `deploy` cannot get a registry token for a unit, that unit's Plan cell reads `could not get registry token`,
  and every later unit reads `not run`. `deploy` refuses an invalid `registry-host` before any unit runs, as `preview`
  does: "Invalid registry host '...'. Use a host name such as registry.example.com, with no https:// or path."
- When `record-image` checks a stage as advice and the check passes, its job summary reads "Result: checked as advice.
  Any failed or undecided assertions are listed below, and they do not fail the step." Otherwise it reads "Result:
  passed." or "Result: failed."
- `preview` and `verify` clear each unit's work directory before the unit runs, so no output of an earlier step in the
  same job shows in the summary.
- `state-unreadable` input on `record-iac`, `false` by default, for `post_deploy`. Set it to `true` when Terraform
  could not read the state after the apply, and leave `state` empty. The CLI then records the apply from the apply log
  alone, and the step fails with "Result: failed without the state file." in the job summary. `deploy` does the same
  on its own and shows "Terraform could not read the state of unit '...' after the apply." Its Post-deploy cell reads
  `failed without the state file`, later units are not deployed, and the post-verify stage does not run. `record-iac`
  stops on:

  | Input | Message |
  | --- | --- |
  | Both `state` and `state-unreadable: true` | "Give either the state input or state-unreadable: true, not both." |
  | `true` at another stage | "The state-unreadable input applies only to the post_deploy stage." |
  | Any value other than `true` or `false` | "The state-unreadable input must be true or false, not '...'." |

  In `examples/iac/governed-own-terraform.yml`, the `post_deploy` step passes `state` when the step that reads the
  state succeeded, and sets `state-unreadable` when it failed.

### Changed

- Some inputs and outputs have new names. Workflows that use the old names must use the new ones.
  `fail-on-failed-assertions: false` replaces `advisory: true`, because the new input means the opposite of the old
  one.

  | Action | Old | New |
  | --- | --- | --- |
  | `record-iac` | `refresh-plans` input | `refresh-only-plans` input |
  | `record-image` | `advisory` input (`true`: failed or undecided assertions do not fail the step) | `fail-on-failed-assertions` input (`true` by default; `false`: failed or undecided assertions do not fail the step) |
  | `deploy`, `preview` | `terraform-version` input | `tool-version` input |
  | `deploy`, `preview` | `terraform-version` output | `tool-version` output |
  | `deploy`, `preview` | `terraform-path` output | `tool-path` output |
  | `close`, `deploy`, `preview`, `record-iac`, `record-image`, `verify` | `working-directory` input | `project-directory` input |

- The reference workflows in `examples/` give every job a time limit: 180 minutes for a deploy job, 10 for a close or
  comment job, and 60 for the others. `examples/iac/deploy.yml` and `examples/iac/own-terraform.yml` say to list the
  project's own assertions and to leave the starter assertions off.
- The job summaries, the pull request comment and the error messages say in words whether each check passed or
  failed, and no longer show exit codes.
- `deploy` and `preview` check that each unit is set up for the environment before Terraform runs for it. A unit is
  not set up when it has backend settings (`config/backend/*.hcl`) or variables (`config/*.tfvars.json`) for other
  environments but not for this one, or when the job sets `TF_WORKSPACE`. `deploy` then stops at that unit, and its
  Plan cell reads `not set up for this environment`. `preview` fails the step, and the unit's result reads
  `not evaluated: the unit is not set up for this environment`. The log says which file is missing.
- `deploy` and `close` run only on `push`, `workflow_dispatch` and `schedule` events. On any other event, the step
  stops with "This action runs only on push, workflow_dispatch and schedule events, not on '...' events. Start the
  workflow with one of them." Pull request events keep their own message.
- The IaC tool runs in a session of its own. When it cannot start, the step fails with "The infrastructure-as-code (IaC)
  tool could not start: ...". When it exits, the action stops every process that the tool or its providers left running.
  When it cannot stop them all within 30 seconds, the step fails with "Some processes the infrastructure-as-code (IaC)
  tool left running could not be stopped within 30 seconds."
- Terraform reads a new, empty Terraform CLI configuration file for each call, and none from the runner's home folder.
- The action fingerprints its tools and the files the step relies on before and after each Terraform call. When any of
  them changed, the step stops with "The action's tools or scripts changed while Terraform ran, so the step stops. Run
  the job again on a fresh runner."
- `deploy` fingerprints a unit's saved plan together with the plan's JSON before the check, and applies the plan only
  when neither changed.
- The step stops with "The CLI's unit list could not be read." when a unit's name or directory holds a control
  character, such as a tab or a line break.
- `preview` adds a file named `zzz_iltero_preview_override.tf` to each unit. It does not plan a unit that already has
  a file or link of that name: "The preview adds a file named zzz_iltero_preview_override.tf to each unit, and this
  unit already has one. Rename the unit's file."
- `preview` names the providers it supports when a unit configures another one: "The preview cannot plan provider
  '...' without credentials. It supports: aws."
- `preview` always gives Terraform mock AWS credentials, also for a unit that configures AWS only in a module.
- In `deploy`, `terraform init`, `terraform plan`, `terraform apply` and the two post-verify readings wait up to 5
  minutes when another run holds the lock on the unit's Terraform state. Terraform locks the state so that two runs
  cannot change it at once. When the lock is still held after 5 minutes, the command fails. `preview` does not lock
  the state.
- After the apply, `deploy` shows in the log each message Terraform wrote, and the detail of each error or warning,
  whether the apply succeeded or failed. When it cannot show them, the log reads "The action could not show the
  apply's messages."
- `preview` reads each unit's committed Terraform lock file and never writes one, as `deploy` does. The lock file,
  `.terraform.lock.hcl`, records the provider versions the unit uses. A unit that uses a provider and has no lock file
  is not evaluated, and the step fails.
- `preview` plans every AWS provider block of a unit without credentials, including blocks with an `alias`. It does
  not plan a unit whose AWS provider `alias` is not a plain name: one that starts with a letter or an underscore and
  holds only letters, digits, underscores and dashes. The log then reads "The preview cannot plan an AWS provider
  block whose alias is not a plain name."
- In `preview`, the result of a unit that could not be planned reads `not evaluated: the preview could not plan the
  unit`, and the step fails. When Terraform fails, the log shows its output, then "Terraform could not plan the unit.
  Its output is above."
- `deploy`, `preview`, `verify`, `record-iac` and `record-image` keep each stack's files in a work folder of its own,
  one for each `project-directory`, so two stacks in one job keep their records and reports apart. The
  `records-directory` output of `deploy` and `preview` names that stack's folder. None of `deploy`, `verify` and
  `preview` uploads or checks a record or report that an earlier step in the job wrote.
- `deploy` and `preview` give Terraform the job's proxy and certificate settings when the job sets them:
  `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, their lower-case forms, `SSL_CERT_FILE` and `SSL_CERT_DIR`. `deploy` also
  gives Terraform `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` and `AWS_CA_BUNDLE` when the job sets them.
- `deploy` and `preview` download each Terraform provider once per job, not once per unit. A provider is the plugin
  through which Terraform manages one cloud or service. Terraform uses a cached provider only when the unit's lock
  file records its checksum.
- When `records-directory` is empty, `record-iac` keeps the records in a directory of its own for each environment and
  `project-directory`, shared by every stage of the stack in that environment. `record-image` keeps them in one
  directory for the builds of each `project-directory`, and one for the deployments of each `project-directory` and
  environment. Give every stage of a stack the same `project-directory`, or the same `records-directory`, so a later
  stage finds the earlier stage's record.
- When the Iltero CLI fails at one of these points, the step ends with the CLI's own exit code, not 1, and shows one
  of these messages after the CLI's own:

  | When | Message |
  | --- | --- |
  | The CLI cannot read `.iltero/config.yml` | "The CLI could not read the project's .iltero/config.yml. Its message above says why." |
  | The CLI cannot list the units | "The CLI could not list the units. Its message above says why." |
  | `setup` installed the CLI, and `iltero doctor` fails | "The Iltero CLI is installed but not ready to run checks. Its message above says what is missing." |
  | `setup` asks the CLI which evaluator release to download, and it fails | "The Iltero CLI could not say which evaluator release to download for ... Its message above says why." |

- `record-iac` refuses a file input that the chosen stage does not read: "Stage plan does not read the apply-log
  input. Remove it from this step." Each stage reads these file inputs:

  | Stage | File inputs it reads |
  | --- | --- |
  | `plan` | `plan`, `saved-plan` |
  | `pre_deploy` | none |
  | `post_deploy` | `plan`, `saved-plan`, `apply-log`, and `state` unless `state-unreadable` is `true` |
  | `post_verify` | `refresh-only-plans`, `state` |

- `close` removes the spaces around its `environment` and `application` inputs before it passes them to the CLI.
- `deploy` and `preview` write no output when the CLI cannot list the units, or when its unit list fails the action's
  checks, so they upload nothing.
- In `examples/iac/own-terraform.yml` and `examples/iac/governed-own-terraform.yml`, `terraform init` uses the unit's
  committed Terraform lock file, `.terraform.lock.hcl`, and never changes it.
- `examples/image/deployment.yml` and `examples/image/governed-deployment.yml` check the image input before any other
  step that uses it. When the image is not named by its digest with no tag, the job stops with "Name the image by its
  digest, as `repository@sha256:<digest>`, where the digest is 64 characters from 0-9 and a-f."
- Every Iltero CLI command that talks to Iltero Platform now refuses to run when `ILTERO_API_URL` names a different
  address from `platform.api_url` in `.iltero/config.yml`. Set both to the same address.
