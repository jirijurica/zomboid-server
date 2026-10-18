#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/terraform/config.tf"
SSM_PREFIX="/zomboid"

fail() {
    echo "Error: $1" >&2
    exit 1
}

# Pre-flight
OVERRIDE=false

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --override) OVERRIDE=true ;;
            *) fail "Unknown argument: $arg" ;;
        esac
    done
}

parse_config() {
    REGION="$(grep -oP '^\s*region\s*=\s*"\K[^"]+' "$CONFIG_FILE" || true)"
    [[ -n "$REGION" ]] || fail "Could not determine region from $CONFIG_FILE."

    ENV="$(grep -oP '^\s*env\s*=\s*"\K[^"]+' "$CONFIG_FILE" || true)"
    [[ -n "$ENV" ]] || fail "Could not determine env from $CONFIG_FILE."
}

check_aws_cli() {
    command -v aws >/dev/null 2>&1 || fail "aws cli is not installed or not on PATH."
    aws sts get-caller-identity >/dev/null 2>&1 || fail "aws cli is not logged in. Run 'aws configure' or 'aws sso login' first."
}

check_region() {
    local current_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"

    [[ -n "$current_region" ]] || fail "Could not determine the AWS CLI region. Set AWS_REGION or run 'aws configure'."
    [[ "$current_region" == "$REGION" ]] || fail "AWS CLI is set to region '$current_region' but Terraform config expects '$REGION'. Switch region (e.g. export AWS_REGION=$REGION) and retry."
}

# Secrets processing
SECRETS=(admin_cidrs server_admin_password server_join_password)
declare -A SECRET_DESCRIPTIONS=(
    [admin_cidrs]="SSH and Prometheus dashboard access whitelist"
    [server_admin_password]="In-game admin account password"
    [server_join_password]="Password required to join the server"
)

get_parameter_path() {
    echo "${SSM_PREFIX}/${ENV}/$1"
}

check_parameter_overridable() {
    local path
    path="$(get_parameter_path "$1")"

    if aws ssm get-parameter --name "$path" >/dev/null 2>&1 && [[ "$OVERRIDE" != true ]]; then
        fail "Parameter $path already exists. Re-run with --override to replace it."
    fi
}

put_ssm_parameter() {
    local name="$1" value="$2" path
    path="$(get_parameter_path "$name")"

    aws ssm put-parameter \
        --name "$path" \
        --type SecureString \
        --value "$value" \
        --overwrite \
        >/dev/null
    echo "  -> stored $path"
}

print_secret_header() {
    local index="$1" total="$2" name="$3" description="$4"
    printf '[%d/%d] %s\n      %s\n' "$index" "$total" "$name" "$description"
}

prompt_password() {
    local label="$1" password confirm

    while true; do
        read -rs -p "  ${label}: " password
        echo >&2
        if [[ -z "$password" ]]; then
            echo "  Password cannot be empty. Try again." >&2
            continue
        fi

        read -rs -p "  Confirm ${label}: " confirm
        echo >&2
        if [[ "$password" != "$confirm" ]]; then
            echo "  Passwords did not match. Try again." >&2
            continue
        fi

        break
    done

    echo "$password"
}

process_secrets() {
    local total=${#SECRETS[@]} index=0 name

    echo "=== Zomboid bootstrap: secrets setup ==="
    echo "Storing secrets as SecureStrings in SSM Parameter Store under ${SSM_PREFIX}/${ENV}/*."
    echo "You'll be prompted for each secret below; leave a line empty to move to the next one."
    echo

    for name in "${SECRETS[@]}"; do
        index=$((index + 1))
        print_secret_header "$index" "$total" "$name" "${SECRET_DESCRIPTIONS[$name]}"
        "process_secret_${name}"
        echo
    done
}

## Secret - Admin CIDRs
validate_cidr() {
    local cidr="$1"

    [[ "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
}

process_secret_admin_cidrs() {
    local cidr value cidrs=()

    check_parameter_overridable "admin_cidrs"

    while true; do
        read -r -p "  CIDR: " cidr
        [[ -z "$cidr" ]] && break

        if validate_cidr "$cidr"; then
            cidrs+=("$cidr")
        else
            echo "  Invalid CIDR '$cidr', expected format x.x.x.x/xx. Try again." >&2
        fi
    done

    [[ "${#cidrs[@]}" -gt 0 ]] || fail "No CIDRs provided, aborting."
    value="$(IFS=';'; echo "${cidrs[*]}")"
    put_ssm_parameter "admin_cidrs" "$value"
}

## Secret - Server Admin Password
process_secret_server_admin_password() {
    local value

    check_parameter_overridable "server_admin_password"
    value="$(prompt_password "Admin password")"
    put_ssm_parameter "server_admin_password" "$value"
}

## Secret - Server Join Password
process_secret_server_join_password() {
    local value

    check_parameter_overridable "server_join_password"
    value="$(prompt_password "Join password")"
    put_ssm_parameter "server_join_password" "$value"
}

# Main
parse_args "$@"
parse_config
check_aws_cli
check_region
process_secrets
