# Iltero Actions

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

GitHub Actions that run [Iltero](https://iltero.io) in a GitHub workflow. They install the Iltero CLI and Terraform,
run Terraform, and hand the results to the CLI. The CLI checks each change and writes its Change Assurance Record.

This repository has no release yet.

## Actions

| Action | Purpose |
| --- | --- |
| `setup` | Install Terraform, the Iltero CLI and its evaluator |
| `open` | Open a governed run on Iltero Cloud |
| `close` | Close a governed run |

See the [documentation](docs/README.md) for inputs, outputs and examples.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues as described in [SECURITY.md](SECURITY.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
