# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. It installs the Iltero command-line tool (CLI) and its evaluator at pinned versions.
- `deploy` action. It plans, checks and applies each unit of a stack, and records each deployment. It records in a
  governed run on Iltero Platform when the project is linked to it, and on the runner when it is not. It applies only
  the saved plan that was checked. In a linked project, `deploy` runs the pre-deploy check before the apply. It plans
  each unit again just before that check, and still applies only the saved plan. It checks after the apply that the
  deployed resources still match. It runs these two checks only when the unit's record requires them.
- `preview` action. It plans each unit of a pull request without cloud credentials and checks each plan locally.
- `comment` action. It posts the preview's result on the pull request and updates the comment on each push.
- `record-iac` action. It records one stage of a unit's change in a workflow that runs Terraform itself. On a pull
  request, it checks the plan locally, as `preview` does.
- `record-image` action. It records the build of a container image and each stage of its deployment.
- `verify` action. It builds each unit's record bundle and checks that the record is consistent with itself and with
  the files it cites.
- `close` action. It closes the governed run of a pipeline run.
- Reference workflows in `examples/` for infrastructure and container images, for projects linked to Iltero Platform
  and for projects that are not.
- Several projects in one repository, each in its own folder, chosen with the `project-directory` input.
- Settings for each unit and environment, read from the unit's own `config/` folder.
- `tool` and `tool-version` inputs on `deploy` and `preview`, which choose the infrastructure-as-code (IaC) tool and
  its version. Terraform is the only supported tool.
- Scanners in a project linked to Iltero Platform. `deploy` and `record-iac` install the scanners the Iltero CLI pins,
  and the run's settings decide which ones run.
- `scan-reports` input on `record-iac`, which gives the plan stage the reports of scanners that the workflow ran.
- `registry-host` input on `deploy` and `preview`, which downloads private modules with the job's GitHub identity
  token.
- `write-report` input on `deploy`, `record-iac` and `verify`, which writes a report of each record as HTML and
  Markdown and adds it to the job summary.
- `store-records` input on `deploy`, `record-iac` and `record-image`, which keeps each record and the files it cites
  in the run's artifact store.
- `fail-on-failed-assertions` input on `record-image`. In a project not linked to Iltero Platform, setting it to
  `false` reports failed or undecided assertions at the plan and pre-deploy stages without failing the step.
- `state-unreadable` input on `record-iac`, which records an apply when Terraform could not read the state afterwards.
- `plan`, `saved-plan` and `replan` inputs on `record-iac` at the pre-deploy stage in a project linked to Iltero
  Platform, which give the check the plan the job will apply and a new plan made just before the apply.
- `environment` and `upload-records` inputs on `preview`.
- `artifact-name` input on `deploy`, `preview`, `record-iac`, `record-image` and `verify`, which names the artifact
  the action uploads.
- `retention-days` input on `deploy`, `record-iac`, `record-image` and `verify`, which sets how long GitHub keeps the
  artifacts the action uploads.
- Terraform runs with a scrubbed environment, also in the governed reference workflow that runs Terraform itself.
- The actions need no Iltero secret. The Iltero CLI signs in with the job's GitHub identity token, so a job that talks
  to Iltero Platform needs `id-token: write`.
- Every action refuses `pull_request_target` and `workflow_run` events. `deploy` and `close` also refuse
  `pull_request` events.
- Job summaries and the pull request comment state each check's result in words and stay within GitHub's size
  limits.
