# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. Installs Terraform, the Iltero CLI and its evaluator at pinned, checksum-verified versions.
- `open` and `close` actions. Open a governed run for the stack in `.iltero/config.yml` and output its id and pins
  digest; close it when the pipeline succeeded.
- `preview` action. Plans each unit of a pull request with no credentials and checks each plan locally.
- `deploy` action. Plans, checks and applies each unit of a stack, and records each deployment: in a governed run when
  the project is linked to Iltero Platform, on the runner alone when it is not. It stops before the plan when a unit
  keeps its Terraform state in its working directory.
- Reference workflows `examples/greenfield.yml` and `examples/preview.yml`.
- `verify` action. Builds each unit's record bundle with `iltero car build` and checks it with `iltero car verify`.
- Example `examples/deploy.yml` for a project with no Iltero account.
- `comment` action. Posts the preview's result as a comment on the pull request, and updates it on each push. The
  `preview` action writes the comment and outputs its artifact name as `comment-artifact`.
