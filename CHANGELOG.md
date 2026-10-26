# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. Installs Terraform, the Iltero CLI and its evaluator at pinned, checksum-verified versions.
- `open` and `close` actions. Open a governed run for the stack in `.iltero/config.yml` and output its id and the
  digest of its settings; close it when the pipeline succeeded.
- `preview` action. Plans each unit of a pull request with no credentials and checks each plan locally.
- `deploy` action. Plans, checks and applies each unit of a stack, and records each deployment: in a governed run when
  the project is linked to Iltero Platform, on the runner alone when it is not. It stops before the plan when a unit
  keeps its Terraform state in its working directory.
- Reference workflows `examples/greenfield.yml` and `examples/preview.yml`.
- `verify` action. Builds each unit's record bundle with `iltero car build` and checks it with `iltero car verify`.
- Example `examples/deploy.yml` for a project with no Iltero account.
- `comment` action. Posts the preview's result as a comment on the pull request, and updates it on each push. The
  `preview` action writes the comment and outputs its artifact name as `comment-artifact`.
- `write-report` input on `deploy` and `verify`, on by default. The CLI writes a report of each unit's record as an
  HTML page and as Markdown. The action uploads both as the artifact `<artifact-name>-report`, adds the Markdown to
  the job summary, and outputs the directory as `report-directory`.
- `registry-host` input on `preview`. When it is set, `terraform init` downloads private modules with the job's GitHub
  identity token, and the job needs `id-token: write`. The project must be linked to Iltero Platform.
- `upload-records` input on `preview`, `false` by default. When it is `true`, the action uploads each unit's records,
  which hold a redacted copy of each plan, as the artifact named by `artifact-name`.
- Settings for each unit, read from the unit's own `config/` folder. For an environment, `deploy` passes
  `config/backend/<environment>.hcl` to `terraform init` as `-backend-config`, and `deploy` and `preview` pass
  `config/<environment>.tfvars.json` to `terraform plan` as `-var-file`. Both files are optional.
