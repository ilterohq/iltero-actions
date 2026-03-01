#!/bin/bash
# =============================================================================
# Iltero Actions - Config Parser Library
# =============================================================================
# Provides functions for parsing and validating stack config.yml files.
# =============================================================================

# =============================================================================
# Parse stack configuration
# =============================================================================

parse_stack_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    # Return stack info as JSON
    yq eval '{
        "stack_id": .stack.id,
        "stack_name": .stack.name,
        "stack_slug": .stack.slug,
        "workspace": .stack.workspace,
        "terraform_version": .terraform.version,
        "bundle_template_id": .bundle.template_bundle_id
    }' "$config_file" -o json
}

# =============================================================================
# Parse brownfield configuration
# =============================================================================

parse_brownfield_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi

    yq eval '{
        "stack_id": .stack.id,
        "stack_name": .stack.name,
        "stack_slug": .stack.slug,
        "workspace": .stack.workspace,
        "stack_type": (.stack.type // "attached"),
        "terraform_working_directory": (.stack.terraform_working_directory // "."),
        "terraform_version": (.terraform.version // "latest")
    }' "$config_file" -o json
}

# =============================================================================
# Parse environment configuration
# =============================================================================

parse_environment_config() {
    local config_file="$1"
    local environment="$2"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    # Return environment config as JSON
    yq eval ".environments.${environment} | {
        \"git_ref_type\": .git_ref.type,
        \"git_ref_name\": .git_ref.name,
        \"compliance_enabled\": (.compliance.enabled // true),
        \"scan_types\": (.compliance.scan_types // [\"static\"]),
        \"block_on_violations\": (.compliance.block_on_violations // true),
        \"frameworks\": (.compliance.frameworks // []),
        \"severity_threshold\": (.security.severity_threshold // \"high\"),
        \"require_approval\": (.deployment.require_approval // false),
        \"auto_apply_on_merge\": (.deployment.auto_apply_on_merge // false)
    }" "$config_file" -o json
}

# =============================================================================
# Parse infrastructure units
# =============================================================================

parse_infrastructure_units() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    # Return enabled units as JSON array
    yq eval '.infrastructure_units[] | select(.enabled != false) | {
        "name": .name,
        "path": .path,
        "enabled": (.enabled // true),
        "depends_on": (.depends_on // []),
        "order": .order
    }' "$config_file" -o json | jq -s '.'
}

# =============================================================================
# Topological sort for units based on depends_on
# =============================================================================

topological_sort_units() {
    local units_json="$1"
    
    echo "$units_json" | python3 -c '
import json
import sys

units = json.load(sys.stdin)
graph = {u["name"]: u.get("depends_on", []) for u in units}
unit_map = {u["name"]: u for u in units}

visited = set()
stack = set()
result = []

def visit(node):
    if node in stack:
        print(f"ERROR: Circular dependency detected involving {node}", file=sys.stderr)
        sys.exit(1)
    if node in visited:
        return
    stack.add(node)
    for dep in graph.get(node, []):
        if dep not in graph:
            print(f"WARNING: Unknown dependency {dep} for {node}, skipping", file=sys.stderr)
            continue
        visit(dep)
    stack.remove(node)
    visited.add(node)
    result.append(unit_map[node])

for name in graph:
    visit(name)

print(json.dumps(result))
'
}

# =============================================================================
# Validate config against schema
# =============================================================================

validate_config_schema() {
    local config_file="$1"
    local schema_file="$2"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Config file not found: $config_file" >&2
        return 1
    fi
    
    if [[ ! -f "$schema_file" ]]; then
        echo "WARNING: Schema file not found, skipping validation" >&2
        return 0
    fi
    
    # Convert YAML to JSON and validate
    local config_json
    config_json=$(yq eval '.' "$config_file" -o json)
    
    echo "$config_json" | python3 -c "
import json
import sys

try:
    from jsonschema import validate, ValidationError
except ImportError:
    print('WARNING: jsonschema not installed, skipping validation', file=sys.stderr)
    sys.exit(0)

config = json.load(sys.stdin)
with open('$schema_file') as f:
    schema = json.load(f)

try:
    validate(instance=config, schema=schema)
    print('Config validation passed')
except ValidationError as e:
    print(f'ERROR: Config validation failed: {e.message}', file=sys.stderr)
    sys.exit(1)
"
}

# =============================================================================
# Get required value with error
# =============================================================================

get_required_value() {
    local config_file="$1"
    local path="$2"
    local name="$3"
    
    local value
    value=$(yq eval "$path" "$config_file" 2>/dev/null)
    
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "ERROR: $name is required in config.yml (path: $path)" >&2
        return 1
    fi
    
    echo "$value"
}

# =============================================================================
# Get optional value with default
# =============================================================================

get_optional_value() {
    local config_file="$1"
    local path="$2"
    local default="$3"
    
    local value
    value=$(yq eval "$path" "$config_file" 2>/dev/null)
    
    if [[ -z "$value" ]] || [[ "$value" == "null" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}
