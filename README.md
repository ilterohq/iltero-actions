# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GitHub Actions that run [Iltero](https://iltero.io) in a GitHub workflow. They install the Iltero CLI and Terraform,
run Terraform, and hand each plan, deployment and pushed container image to the CLI. The CLI checks each change and
writes its Change Assurance Record (CAR).

A pipeline run is one run of a CI pipeline; on GitHub, a workflow run. A governed run is a run that Iltero Platform
opens for a pipeline run and holds to fixed settings: the assertions that must pass, whether a failed assertion blocks
the change, and whether the environment is production. A change run is a governed run of one stack in one environment. A
build run is a governed run that builds one application's container image, in no environment.

This repository has no release.

## Actions

| Action | Purpose |
| --- | --- |
| `setup` | Install the Iltero CLI, its evaluator (the policy engine that runs the assertions) and, unless `install-terraform` is `false`, Terraform, at pinned, checksum-verified versions |
| `deploy` | Plan, check and apply each unit of a stack: in a governed run when the project is linked to Iltero Platform, locally on the runner when it is not. After the apply, check that the deployed resources still match what the apply left, for each unit whose record expects that check |
| `record-iac` | Record one stage of one unit's Terraform change in a job that runs Terraform itself: after plan, before apply, after apply, or a check of the deployed resources after the apply |
| `record-image` | Record one stage of a container image's change. The plan stage records the image a build pushed, in the same pipeline run as the build. The deployment stages record the image before and after its deployment to an environment, and check the workload's pods after the rollout |
| `close` | Close the governed run of this pipeline run on Iltero Platform: the change run of a stack and environment, or the build run of an application |
| `verify` | Pack each unit's record and every file it cites into a record bundle, and check the bundle |
| `preview` | Plan and check each unit on a pull request, locally and with no cloud credential or Iltero secret, and write the pull request comment |
| `comment` | Post the preview's comment on the pull request, and update it on each push |

A project is linked to Iltero Platform when its `.iltero/config.yml` has a `platform` section. In a linked project,
the plan stage's check opens a change run on Iltero Platform for the pipeline run, stack and environment. Each
later stage joins that run. `deploy` and `record-iac` send each stage's record. At the plan stage, `record-image`
opens or joins the build run of the pipeline run for an application, and sends the image's record. `record-image`
records a deployment of an image only in an unlinked project. An unlinked project records on the runner alone.

Copy a workflow from [`examples/`](examples/README.md) to start. See [`docs/README.md`](docs/README.md) for what a job
needs and how to run the checks.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
