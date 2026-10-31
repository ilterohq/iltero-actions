# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. Installs Terraform, the Iltero CLI and its evaluator at pinned, checksum-verified versions.
- `close` action. Closes the run of the pipeline run for the stack in `.iltero/config.yml` and an environment. It takes
  `environment` (required) and `working-directory` (`.` by default).
- `preview` action. Plans each unit of a pull request with no credentials and checks each plan locally.
- `deploy` action. Plans, checks and applies each unit of a stack, and records each deployment: in a governed run when
  the project is linked to Iltero Platform, on the runner alone when it is not. It stops before the plan when a unit
  keeps its Terraform state in its working directory.
- Reference workflows `examples/greenfield.yml` and `examples/preview.yml`.
- `verify` action. Builds each unit's record bundle with `iltero record build` and checks it with
  `iltero record verify`.
- Example `examples/deploy.yml` for a project with no Iltero account.
- `comment` action. Posts the preview's result as a comment on the pull request, and updates it on each push. The
  `preview` action writes the comment and outputs its artifact name as `comment-artifact`.
- `write-report` input on `deploy` and `verify`, on by default. The CLI writes a report of each unit's record as an
  HTML page, `record-report.html`, and as Markdown, `record-report.md`. The action uploads both as the artifact
  `<artifact-name>-report`, adds the Markdown to the job summary, and outputs the directory as `report-directory`.
  When the CLI does not write both files for a unit, the step fails at its end. In `deploy`, a unit whose deploy
  failed sets the step's exit code.
- `registry-host` input on `preview`. When it is set, `terraform init` downloads private modules with the job's GitHub
  identity token, and the job needs `id-token: write`. The project must be linked to Iltero Platform.
- `upload-records` input on `preview`, `false` by default. When it is `true`, the action uploads each unit's records,
  which hold a redacted copy of each plan, as the artifact named by `artifact-name`.
- `environment` input on `preview`, empty by default. When it is empty, the Iltero CLI finds the environment from the
  pull request's target branch. Set it when the target branch deploys to several environments, for example `main` to
  `staging` and then `production`. The action then checks the change against the named environment. The `setup` action
  installs an Iltero CLI that lets one branch deploy to several environments. `examples/preview.yml` shows the input.
  When the input is empty and the CLI cannot choose an environment (exit code 2), the step adds the notice "When the
  target branch deploys to several environments, name one with the preview action's environment input." The step
  keeps the CLI's exit code.
- `deploy` and `preview` refuse an environment that cannot name a unit's settings file, before anything runs. Such a
  name contains `/`, or is `.` or `..`. The step stops with "The environment '...' cannot name a unit's settings
  file. Use a name without '/'."
- Settings for each unit, read from the unit's own `config/` folder. For an environment, `deploy` passes
  `config/backend/<environment>.hcl` to `terraform init` as `-backend-config`, and `deploy` and `preview` pass
  `config/<environment>.tfvars.json` to `terraform plan` as `-var-file`. Both files are optional.
- `record-iac` action, and the example `examples/record-iac.yml`. In a job that runs Terraform itself, the action
  records one stage of one unit's change from the files that Terraform wrote: `plan`, `pre_deploy` (before the apply),
  `post_deploy` (after the apply) or `post_verify` (after `post_deploy`). It runs no Terraform. For a project not linked
  to Iltero Platform, `pre_deploy` is not in scope and checks nothing. `pre_deploy` reads the `plan` stage's record from
  `records-directory`. Its records artifact is named `iltero-records-<unit>` unless `artifact-name` is set.
  `post_verify` checks that the deployed resources still match what the apply left. It takes the input
  `refresh-plans`: two readings of the deployed resources, one path per line, in the order they were taken. Each reading
  is a refresh-only plan, from `terraform plan -refresh-only -out=FILE` then `terraform show -json FILE`, and the second
  is taken at least 60 seconds after the first. Any other number of readings stops the step: "The refresh-plans input
  must name two readings, one per line, in the order they were taken." The example takes both readings after
  `post_deploy`.
- `install-terraform` input on `setup`, `true` by default. When it is `false`, `setup` does not install Terraform, for a
  job that runs its own Terraform and uses `record-iac`. The outputs `terraform-version` and `terraform-path` are then
  empty. Any value other than `true` or `false` stops the step: "The install-terraform input must be true or false,
  not '...'." The example `examples/record-iac.yml` sets it to `false`.
- Post-verify stage in `deploy`. When every unit deployed, `deploy` checks that the deployed resources of each unit
  whose record expects the post-verify stage still match what the apply left. It reads each such unit back twice with
  `terraform plan -refresh-only`, with the same variable files as the plan, and never applies a reading. The second
  reading comes at least 61 seconds after the first, and the log says how long the deploy waits. It then runs
  `iltero iac check --stage post_verify` with `--minimum-interval-seconds 60`. A failed unit does not stop the others.
  The step fails with the first failing code: "The post-verify stage failed for one or more units. See the job
  summary." A reading that fails reads "Terraform could not read back unit '...'." No unit is read
  back when a unit failed to deploy. Each unit's report is written after its post-verify stage. A record that cannot be
  read fails the step, after the other units, with "The CLI's record of unit '...' could not be read."
- `readings-directory` output on `deploy`. It names the folder that holds each unit's two readings, as
  `<unit>/first.json` and `<unit>/second.json`. The readings can hold secret values. The action does not upload them,
  and they are not meant to be kept: the record keeps only their digests.

### Changed

- Runs on Iltero Platform need no step to open them and no run id between jobs. In a project linked to Iltero
  Platform, the plan stage's check opens the run for the pipeline run, stack and environment, and each later stage
  joins it. `deploy` and `record-iac` send each stage's record. The `setup` action installs an Iltero CLI that
  does this. A project with no `platform` section records on the runner, as before.

  A workflow copied from `examples/greenfield.yml` or `examples/record-iac.yml` must change:

  1. Remove the `open` step and the job outputs that carried its values.
  2. Remove `run-id` and `run-settings-digest` from every `deploy` and `record-iac` step.
  3. In each `close` step, replace `run-id` with `environment`, set to the environment the deploy job used.
  4. In each `close` job, check out the repository before `setup`, and grant `contents: read`.

  | Action | Removed input | New input |
  | --- | --- | --- |
  | `deploy` | `run-id`, `run-settings-digest` | None |
  | `record-iac` | `run-id`, `run-settings-digest` | None |
  | `close` | `run-id` | `environment` (required), `working-directory` (`.` by default) |

- `preview` and `record-iac` on a pull request check each plan locally, also for a project linked to Iltero Platform.
  The check never contacts Iltero Platform, and its record is not evidence of the change. It checks the project's own
  assertions, while the checks after the merge use the assertions that Iltero Platform sets. A linked project's
  `preview` needs no `ILTERO_API_URL` and, unless `registry-host` is set, no `id-token: write`. The `setup` action
  installs an Iltero CLI that allows this.
- `record-iac` refuses `pull_request_review` and `pull_request_review_comment` events, which it used to accept for the
  `plan` stage. The step stops with "record-iac does not run on <event> events. Run it on pull_request events,
  where it checks the plan locally."
- `deploy` and `preview` message when Terraform is missing. It now reads "Terraform is not installed. Run the setup
  action first in this job, with install-terraform true."
- `deploy` job summary. The table has a Post-verify column. Each cell reads `exit N` (the CLI's exit code),
  `not in scope`, `terraform failed`, `record unreadable`, or `-` when a unit failed to deploy and no unit was read
  back.

### Removed

- `open` action. The plan stage's check opens the run.
- The messages that asked for `run-id` and `run-settings-digest`, or asked to leave them empty. On a pull request,
  `record-iac` no longer mentions them.
