# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GitHub Actions that run [Iltero](https://iltero.io) in a GitHub workflow. They install the Iltero CLI and Terraform,
run Terraform, and hand each plan and deployment to the CLI. The CLI checks each change and writes its Change
Assurance Record (CAR).

This repository has no release.

## Actions

| Action | Purpose |
| --- | --- |
| `setup` | Install the Iltero CLI, its evaluator and, unless `install-terraform` is `false`, Terraform, at pinned, checksum-verified versions |
| `deploy` | Plan, check and apply each unit of a stack: in a governed run when the project is linked to Iltero Platform, locally on the runner when it is not. After the apply, check that the deployed resources still match what the apply left, for each unit whose record expects that check |
| `record-iac` | Record one stage of one unit's Terraform change in a job that runs Terraform itself: after plan, before apply, after apply, or a check of the deployed resources after the apply |
| `close` | Close the run of a pipeline run on Iltero Platform, for a stack and environment |
| `verify` | Pack each unit's record with every file it cites, and check it |
| `preview` | Plan and check each unit on a pull request, locally and with no cloud credential or Iltero secret, and write the pull request comment |
| `comment` | Post the preview's comment on the pull request, and update it on each push |

A project is linked to Iltero Platform when its `.iltero/config.yml` has a `platform` section. In a linked project,
the plan stage's check opens a run on Iltero Platform for the pipeline run, stack and environment. Each later stage
joins that run. `deploy` and `record-iac` send each stage's record. An unlinked project records on the runner
alone.

Copy a workflow from [`examples/`](examples/README.md) to start. See [`docs/README.md`](docs/README.md) for what a job
needs and how to run the checks.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
