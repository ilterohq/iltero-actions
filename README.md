# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GitHub Actions that run [Iltero](https://iltero.io) in a GitHub workflow. They install the Iltero command-line tool
(CLI) and Terraform, run Terraform, and hand each plan, deployment and pushed container image to the CLI. The CLI
checks each change and writes a record of it, the Change Assurance Record: what was checked, against which inputs, and
with which result.

Pin each action to the commit SHA of a release, as [`docs/README.md`](docs/README.md) explains.

## Terms

- A **stack** is the infrastructure that one project folder deploys. A **unit** is one part of a stack that the
  infrastructure-as-code (IaC) tool plans and applies on its own. `iltero units list` prints a stack's units. For a
  container image, the unit is the part of the project the image is built from or deployed as.
- An **assertion** is one rule a change must pass, such as "every storage bucket blocks public access". The
  **evaluator** is the program that runs the assertions.
- A **stage** is one point of a change that the CLI checks: `plan` (after the plan; for an image, after its build),
  `pre_deploy` (before the apply or the deployment), `post_deploy` (after it) and `post_verify` (later, a check that
  what was deployed still matches).
- A **record bundle** is a folder that holds a unit's record and every file the record cites.
- A **pipeline run** is one run of a continuous integration (CI) pipeline; on GitHub, a workflow run.
- A project is **linked to Iltero Platform** when its `.iltero/config.yml` has a `platform` section. A project not
  linked to Iltero Platform records locally (on the runner) and sends nothing to Iltero Platform.

## Governed runs

In a project linked to Iltero Platform, every stage of a change is checked in a governed run, so all its stages use
the same settings. Iltero Platform opens the run when the CLI checks the first stage, and each later stage joins it.
Iltero Platform sets the run's settings: the assertions that must pass, whether a failed assertion blocks the change,
and whether the environment is production. The `close` action closes the run.

| Governed run | What it covers | Opened by |
| --- | --- | --- |
| Change run | One stack in one environment | The `plan` stage of `deploy` or `record-iac` |
| Build run | One application's container image build, in no environment | The `plan` stage of `record-image` |
| Image deploy run | One application's image, deployed to one environment | The first deployment stage of `record-image` |

`deploy`, `record-iac` and `record-image` send each stage's record to the run.

## Actions

| Action | Purpose |
| --- | --- |
| `setup` | Install the Iltero CLI and its evaluator, at pinned, checksum-verified versions |
| `deploy` | Install the IaC tool, then plan, check and apply each unit of a stack: in a governed run when the project is linked to Iltero Platform, locally (on the runner) when it is not. After the apply, check that the deployed resources still match what the apply left, for each unit whose plan-stage record says the check is required |
| `record-iac` | Record one stage of one unit's Terraform change in a job that runs Terraform itself: after plan, before apply, after apply, or a check of the deployed resources after the apply |
| `record-image` | Record one stage of a container image's change. The `plan` stage records the image a build pushed, in the same pipeline run as the build. The deployment stages record the image before and after its deployment to an environment, and check the workload's pods after the rollout |
| `close` | Close the governed run of this pipeline run on Iltero Platform: the change run of a stack and environment, the build run of an application, or the image deploy run of an application and environment |
| `verify` | Build the record bundle of each unit, or of one named unit, and check that the record is consistent with itself and with the files it cites |
| `preview` | Install the IaC tool, then plan and check each unit on a pull request, locally and with no cloud credential or Iltero secret, and write the pull request comment |
| `comment` | Post the preview's comment on the pull request, and update it on each push |

Copy a workflow from [`examples/`](examples/README.md) to start. See [`docs/README.md`](docs/README.md) for what a job
needs and how to run the checks.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
