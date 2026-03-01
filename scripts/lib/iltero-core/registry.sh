#!/bin/bash
# =============================================================================
# Iltero Core - Registry Configuration
# =============================================================================
# Functions for configuring private module registry authentication.
# =============================================================================

# Configure credentials for private module registry
# Args: $1=token $2=registry_host
# Returns: 0 if configured (or skipped), 1 on error
configure_registry() {
    local token="${1:-${ILTERO_REGISTRY_TOKEN:-}}"
    local registry_host="${2:-registry.iltero.io}"

    if [[ -z "$token" ]]; then
        log_info "ILTERO_REGISTRY_TOKEN not set - skipping private registry authentication"
        return 0
    fi

    log_info "Configuring credentials for private module registry: $registry_host"

    # Configure Terraform CLI credentials file (.terraformrc) for native registry protocol
    local tf_rc_file="${HOME}/.terraformrc"
    cat > "$tf_rc_file" << EOF
credentials "${registry_host}" {
  token = "${token}"
}
EOF
    chmod 600 "$tf_rc_file"
    log_info "Created ${tf_rc_file} with credentials for ${registry_host}"

    # Configure .netrc file (for downloading module packages via HTTP)
    local netrc_file="${HOME}/.netrc"

    # Overwrite .netrc with proper format (machine on first line, no leading spaces)
    cat > "$netrc_file" << EOF
machine ${registry_host}
login x-access-token
password ${token}
EOF

    chmod 600 "$netrc_file"

    # Configure git credential helper
    _setup_git_credential_helper "$registry_host"

    # Debug: verify files were created
    log_info "Verifying credentials files..."
    if [[ -f "$tf_rc_file" ]]; then
        log_info ".terraformrc exists with $(wc -l < "$tf_rc_file") lines"
    fi
    if [[ -f "$netrc_file" ]]; then
        log_info ".netrc exists with $(wc -l < "$netrc_file") lines"
    fi

    log_success "Private registry credentials configured"
    return 0
}

# Setup git credential helper for registry (internal helper)
# Args: $1=registry_host
_setup_git_credential_helper() {
    local registry_host="$1"
    local cred_helper="${HOME}/.git-credential-netrc"

    cat > "$cred_helper" << 'HELPER'
#!/bin/bash
if [[ "$1" == "get" ]]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^host=(.+)$ ]]; then
      host="${BASH_REMATCH[1]}"
    fi
  done
  if [[ -n "$host" ]] && [[ -f "$HOME/.netrc" ]]; then
    awk -v host="$host" '
      /machine/ { m = ($2 == host) }
      m && /login/ { print "username=" $2 }
      m && /password/ { print "password=" $2 }
    ' "$HOME/.netrc"
  fi
fi
HELPER
    chmod +x "$cred_helper"

    git config --global credential."https://${registry_host}".helper "$cred_helper"
    git config --global credential."https://${registry_host}".useHttpPath true
}
