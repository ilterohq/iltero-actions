# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GitHub Actions that run [Iltero](https://iltero.io) in a GitHub workflow. They install the Iltero CLI and Terraform,
run Terraform, and hand each plan and deployment to the CLI. The CLI checks each change and writes its Change
Assurance Record (CAR).

This repository has no release.

## Actions

| Action | Purpose |
| --- | --- |
| `setup` | Install Terraform, the Iltero CLI and its evaluator at pinned, checksum-verified versions |
| `open` | Open a governed run on Iltero Platform, and output its run id and pins digest |
| `deploy` | Plan, check and apply each unit of a stack: in a governed run when the project is linked to Iltero Platform, locally on the runner when it is not |
| `close` | Close a governed run |
| `verify` | Pack each unit's record with every file it cites, and check it |
| `preview` | Plan and check each unit on a pull request, locally and with no cloud or Iltero credential, and write the pull request comment |
| `comment` | Post the preview's comment on the pull request, and update it on each push |

A project is linked to Iltero Platform when its `.iltero/config.yml` has a `platform` section.

Copy a workflow from [`examples/`](examples/README.md) to start. See [`docs/README.md`](docs/README.md) for what a job
needs and how to run the checks.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
