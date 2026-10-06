# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `setup` action. Installs Terraform, the Iltero CLI and its evaluator at pinned, checksum-verified versions.
- `open` and `close` actions. Open a governed run and output its id and pins digest; close it when the pipeline
  succeeded.
