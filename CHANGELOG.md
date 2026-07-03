# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-07-02

### Fixed

- PR-preview evaluation now runs `terraform plan` with no cloud credentials, so
  policies evaluate the plan JSON on every PR (including forks). Cloud-agnostic
  per-provider setup (AWS implemented); the credentialed deploy path is
  unchanged, and a preview never enters the evidence/provenance chain.

## [0.1.0] - 2026-06-26

### Added

- Initial release.
