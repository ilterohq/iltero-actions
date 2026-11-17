#!/bin/bash
#
# Installs the pinned infrastructure-as-code (IaC) tool that the deploy and preview actions run.
#
# Usage:
#   iac/install-tool.sh TOOL VERSION   Install VERSION of TOOL, checked against the
#                                      checksums pinned in its adapter. An empty
#                                      VERSION installs the adapter's default version.
#
# Writes the outputs tool-version and tool-path.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/tool.sh"

main() {
  [[ $# -eq 2 ]] || die "Usage: iac/install-tool.sh TOOL VERSION"
  load_tool "$1"
  local version="${2:-${TOOL_DEFAULT_VERSION}}"
  tool_install "${version}"
  write_output tool-version "${version}"
  write_output tool-path "${TOOL_INSTALLED_PATH}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
