#!/bin/bash
# HelloCron client | https://hellocron.com

CONFIG_FILE="${HOME}/.hellocron.conf"
LEGACY_CONFIG_FILE="${HOME}/.hellocron-config.json"
# The service runs at a fixed address, so a config file only needs the API key.
# These two are written back only when pointed somewhere else (self-hosted, staging).
# Reported with every ping as "host". A container gets a random hex hostname, so
# it can be pinned with hostname= in the config file or HELLOCRON_HOSTNAME.
HOSTNAME_OVERRIDE="${HELLOCRON_HOSTNAME:-}"

DEFAULT_API_URL="https://api.hellocron.com"
DEFAULT_API_PING_ENDPOINT="/ping"
API_URL="$DEFAULT_API_URL"
API_PING_ENDPOINT="$DEFAULT_API_PING_ENDPOINT"
HELLOCRON_API_KEY=""
TELEMETRY_ENABLED=true
DEFAULT_PROJECT=""
VERBOSE=false
ALLOW_INSECURE=false

# Management credentials live apart from the ingest config on purpose. The
# ingest key (ck_) belongs on every monitored host and is routinely shipped
# around by configuration management; the management key (mk_) can delete
# monitors together with their event history. Keeping them in one file means a
# single copy step fans a destructive credential out across the fleet.
#
# Unlike the settings above, these two read from the environment first so CI can
# inject them as secrets without touching any file.
MANAGEMENT_CONFIG_FILE="${HOME}/.hellocron-management.conf"
HELLOCRON_MANAGEMENT_KEY="${HELLOCRON_MANAGEMENT_KEY:-}"
PANEL_URL="${HELLOCRON_PANEL_URL:-https://app.hellocron.com}"

DEFAULT_TIMEOUT=30
DEFAULT_PING_TIMEOUT=5

MAX_ERROR_OUTPUT_SIZE=10240

VERSION="1.5"
VERSION_DATE="2026-09-12"
VERSION_BUILD="${VERSION_DATE//-/}"
VERSION_BUILD="${VERSION_BUILD:2}"
VERSION_TAG="v${VERSION}-${VERSION_BUILD}"
APP_NAME="HelloCronClient ${VERSION_TAG}"

header() {
    # Brand green from the logo (#4ADE80); plain green where truecolor is unsupported
    local green="\033[32m"
    [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]] && green="\033[38;2;74;222;128m"
    local bold="\033[1m" dim="\033[2m" reset="\033[0m"
    local meta="${VERSION_TAG} · hellocron.com"
    local rule
    rule=$(printf '─%.0s' $(seq 1 ${#meta}))
    echo ""
    echo -e "${bold}hello${green}:${reset}${bold}cron${reset}  ${dim}shell client${reset}"
    echo -e "${green}${rule}${reset}"
    echo -e "${dim}${meta}${reset}"
    echo ""
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    case "$level" in
        info)
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "\033[0;32m[INFO]\033[0m $message"
            fi
            ;;
        warn)
            echo -e "\033[0;33m[WARN]\033[0m $message" >&2 ;;
        error)
            echo -e "\033[0;31m[ERROR]\033[0m $message" >&2 ;;
        debug)
            if [[ "$DEBUG" == "true" || "$VERBOSE" == "true" ]]; then
                echo -e "\033[0;36m[DEBUG]\033[0m $message" >&2
            fi
            ;;
        *)
            echo "$message" ;;
    esac
}

handle_error() {
    local exit_code=$1
    local message="${2:-An unexpected error occurred}"

    log "error" "$message"
    exit $exit_code
}

HTTP_TOOL=""
detect_http_tool() {
    if command -v curl &> /dev/null; then
        HTTP_TOOL="curl"
    elif command -v wget &> /dev/null; then
        HTTP_TOOL="wget"
    else
        HTTP_TOOL=""
    fi
}

check_dependencies() {
    detect_http_tool
    if [[ -z "$HTTP_TOOL" ]]; then
        log "warn" "curl and wget not found - telemetry disabled, jobs will run without monitoring"
        TELEMETRY_ENABLED=false
    fi
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

json_number() {
    local v="$1"
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$v"
    else
        printf '0'
    fi
}

validate_api_url() {
    local url="$1"

    if [[ -z "$url" ]]; then
        log "error" "API URL cannot be empty"
        return 1
    fi

    if [[ ! "$url" =~ ^https?:// ]]; then
        log "error" "API URL must start with http:// or https://"
        return 1
    fi

    if [[ "$url" =~ ^http:// ]]; then
        log "warn" "⚠️  WARNING: You are using insecure HTTP! Data will be sent unencrypted."
        log "warn" "⚠️  HTTPS is recommended for security."
    fi

    if [[ "$url" =~ localhost|127\.0\.0\.1 ]]; then
        log "debug" "Using localhost - OK for development"
    fi

    return 0
}

truncate_output() {
    local output="$1"
    local max_size="${2:-$MAX_ERROR_OUTPUT_SIZE}"

    if [[ ${#output} -gt $max_size ]]; then
        local truncated="${output:0:$max_size}"
        echo "${truncated}... [TRUNCATED: original size ${#output} bytes, showing ${max_size} bytes]"
    else
        echo "$output"
    fi
}

config_get_string() {
    local key="$1"
    local file="$2"
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | head -n1
}

config_get_raw() {
    local key="$1"
    local file="$2"
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([a-z0-9.]*\).*/\1/p' "$file" 2>/dev/null | head -n1
}

load_config_json() {
    local file="$1"
    local val

    val=$(config_get_string "api_url" "$file")
    [[ -n "$val" ]] && API_URL="$val"

    val=$(config_get_string "api_key" "$file")
    [[ -n "$val" ]] && HELLOCRON_API_KEY="$val"

    val=$(config_get_raw "telemetry_enabled" "$file")
    if [[ "$val" == "true" || "$val" == "false" ]]; then
        TELEMETRY_ENABLED="$val"
    fi

    val=$(config_get_string "default_project" "$file")
    [[ -n "$val" ]] && DEFAULT_PROJECT="$val"
}

load_config_kv() {
    local file="$1"
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"="* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        case "$key" in
            api_url)           [[ -n "$value" ]] && API_URL="$value" ;;
            api_ping_endpoint) [[ -n "$value" ]] && API_PING_ENDPOINT="$value" ;;
            api_key)           [[ -n "$value" ]] && HELLOCRON_API_KEY="$value" ;;
            telemetry_enabled) [[ "$value" == "true" || "$value" == "false" ]] && TELEMETRY_ENABLED="$value" ;;
            default_project)   DEFAULT_PROJECT="$value" ;;
            hostname)          [[ -z "${HELLOCRON_HOSTNAME:-}" && -n "$value" ]] && HOSTNAME_OVERRIDE="$value" ;;
        esac
    done < "$file"
}

load_config() {
    local file="$CONFIG_FILE"

    if [[ ! -f "$file" && -f "$LEGACY_CONFIG_FILE" ]]; then
        file="$LEGACY_CONFIG_FILE"
    fi

    if [[ ! -f "$file" ]]; then
        log "debug" "Config file not found, using defaults"
        return 0
    fi

    local first_char
    first_char=$(sed -n 's/^[[:space:]]*\(.\).*/\1/p' "$file" 2>/dev/null | head -n1)

    if [[ "$first_char" == "{" ]]; then
        load_config_json "$file"
    else
        load_config_kv "$file"
    fi

    log "debug" "Configuration loaded from $file"
}

# Management key and panel URL, in precedence order:
#   1. environment (HELLOCRON_MANAGEMENT_KEY / HELLOCRON_PANEL_URL)
#   2. ~/.hellocron-management.conf
# Never ~/.hellocron.conf - see the note next to MANAGEMENT_CONFIG_FILE.
load_management_config() {
    [[ -f "$MANAGEMENT_CONFIG_FILE" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"="* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        case "$key" in
            management_key) [[ -z "$HELLOCRON_MANAGEMENT_KEY" && -n "$value" ]] && HELLOCRON_MANAGEMENT_KEY="$value" ;;
            panel_url)      [[ -z "${HELLOCRON_PANEL_URL:-}" && -n "$value" ]] && PANEL_URL="$value" ;;
        esac
    done < "$MANAGEMENT_CONFIG_FILE"

    log "debug" "Management config loaded from $MANAGEMENT_CONFIG_FILE"
}

save_management_config() {
    mkdir -p "$(dirname "$MANAGEMENT_CONFIG_FILE")"

    umask 077

    printf 'panel_url=%s\nmanagement_key=%s\n' "$PANEL_URL" "$HELLOCRON_MANAGEMENT_KEY" > "$MANAGEMENT_CONFIG_FILE"

    if [[ $? -eq 0 ]]; then
        chmod 600 "$MANAGEMENT_CONFIG_FILE" 2>/dev/null
        log "warn" "Management key stored in plaintext at $MANAGEMENT_CONFIG_FILE (permissions: 600)."
        log "warn" "Do NOT copy this file to monitored servers - it can delete monitors and their history."
    else
        log "error" "Cannot write management configuration to $MANAGEMENT_CONFIG_FILE"
        return 1
    fi
}

# Resolve and sanity-check the management key before any management request.
# Catching a swapped key here turns an opaque 401 into an actionable message.
require_management_key() {
    load_management_config

    if [[ -z "$HELLOCRON_MANAGEMENT_KEY" ]]; then
        log "error" "No management key found."
        log "error" "Set HELLOCRON_MANAGEMENT_KEY, or run: $0 configure --management-key"
        log "error" "Generate the key in the panel under Settings -> API key (Management API Key)."
        return 1
    fi

    if [[ "$HELLOCRON_MANAGEMENT_KEY" == ck_* ]]; then
        log "error" "That looks like an ingest key (ck_). Management commands need a management key (mk_)."
        log "error" "Generate one in the panel under Settings -> API key (Management API Key)."
        return 1
    fi

    if ! validate_api_url "$PANEL_URL"; then
        log "error" "Invalid panel URL. Set HELLOCRON_PANEL_URL or panel_url in $MANAGEMENT_CONFIG_FILE"
        return 1
    fi

    return 0
}

# Unlike api_request(), this returns the response BODY on stdout - the whole
# value of apply/export is in the report, not in the status code. The status
# code lands in MANAGEMENT_HTTP_CODE.
MANAGEMENT_HTTP_CODE=""
management_request() {
    local method="$1"
    local path="$2"
    local body_file="$3"
    local url="${PANEL_URL}${path}"

    [[ -z "$HTTP_TOOL" ]] && detect_http_tool

    if [[ "$HTTP_TOOL" == "curl" ]]; then
        local curl_opts=(
            -X "$method"
            -s
            -w $'\n%{http_code}'
            -H "Content-Type: application/json"
            -H "Accept: application/json"
            -H "Authorization: Bearer $HELLOCRON_MANAGEMENT_KEY"
            --connect-timeout "$DEFAULT_PING_TIMEOUT"
            --max-time "$DEFAULT_TIMEOUT"
        )

        [[ "$ALLOW_INSECURE" == "true" ]] && curl_opts+=(--insecure)
        [[ -n "$body_file" ]] && curl_opts+=(--data-binary "@$body_file")

        local response
        response=$(curl "${curl_opts[@]}" "$url" 2>/dev/null)

        MANAGEMENT_HTTP_CODE="${response##*$'\n'}"
        printf '%s' "${response%$'\n'*}"

    elif [[ "$HTTP_TOOL" == "wget" ]]; then
        local wget_opts=(
            -q -O -
            --method="$method"
            --header="Content-Type: application/json"
            --header="Accept: application/json"
            --header="Authorization: Bearer $HELLOCRON_MANAGEMENT_KEY"
            --tries=1
            --timeout="$DEFAULT_TIMEOUT"
        )

        [[ "$ALLOW_INSECURE" == "true" ]] && wget_opts+=(--no-check-certificate)
        [[ -n "$body_file" ]] && wget_opts+=(--body-file="$body_file")
        wget --help 2>&1 | grep -q -- --content-on-error && wget_opts+=(--content-on-error)

        local output
        if output=$(wget "${wget_opts[@]}" "$url" 2>/dev/null); then
            MANAGEMENT_HTTP_CODE="200"
        else
            MANAGEMENT_HTTP_CODE="000"
        fi
        printf '%s' "$output"
    else
        log "error" "Neither curl nor wget is available"
        MANAGEMENT_HTTP_CODE="000"
        return 1
    fi

    [[ "$MANAGEMENT_HTTP_CODE" == 2* ]]
}

# Keys end up in screenshots and shared terminals, so prompts show a stub.
mask_key() {
    local k="$1"
    if [[ ${#k} -le 12 ]]; then
        printf '***'
    else
        printf '%s...%s' "${k:0:8}" "${k: -4}"
    fi
}

resolve_hostname() {
    if [[ -n "$HOSTNAME_OVERRIDE" ]]; then
        printf '%s' "$HOSTNAME_OVERRIDE"
    else
        hostname
    fi
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"

    umask 077

    local telemetry_bool="false"
    [[ "$TELEMETRY_ENABLED" == "true" ]] && telemetry_bool="true"

    {
        # Only an overridden endpoint is worth writing down; the default lives
        # in the script, so an upgrade moves every host at once.
        [[ "$API_URL" != "$DEFAULT_API_URL" ]] && printf 'api_url=%s\n' "$API_URL"
        [[ "$API_PING_ENDPOINT" != "$DEFAULT_API_PING_ENDPOINT" ]] && printf 'api_ping_endpoint=%s\n' "$API_PING_ENDPOINT"
        [[ -n "$HOSTNAME_OVERRIDE" ]] && printf 'hostname=%s\n' "$HOSTNAME_OVERRIDE"
        printf 'api_key=%s\ntelemetry_enabled=%s\ndefault_project=%s\n' \
            "$HELLOCRON_API_KEY" \
            "$telemetry_bool" \
            "$DEFAULT_PROJECT"
    } > "$CONFIG_FILE"

    if [[ $? -eq 0 ]]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log "info" "Configuration saved to $CONFIG_FILE (permissions: 600)"

        if [[ -n "$HELLOCRON_API_KEY" ]]; then
            log "warn" "⚠️  API key is stored in plaintext. Make sure $CONFIG_FILE is secure!"
        fi
    else
        log "error" "Cannot write configuration to $CONFIG_FILE"
    fi
}

api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local url="${API_URL}${endpoint}"

    if ! validate_api_url "$API_URL"; then
        log "error" "Invalid API URL. Configure a valid URL with: $0 configure"
        return 1
    fi

    [[ -z "$HTTP_TOOL" ]] && detect_http_tool

    if [[ "$HTTP_TOOL" == "curl" ]]; then
        local curl_opts=(
            -X "$method"
            -s
            -o /dev/null
            -w '%{http_code}'
            -H "Content-Type: application/json"
            --connect-timeout "$DEFAULT_PING_TIMEOUT"
            --max-time "$DEFAULT_TIMEOUT"
        )

        if [[ "$ALLOW_INSECURE" == "true" ]]; then
            log "warn" "⚠️  WARNING: SSL verification disabled (--insecure). This is DANGEROUS!"
            curl_opts+=(--insecure)
        fi

        if [[ "$HELLOCRON_API_KEY" == mk_* ]]; then
            log "error" "The configured api_key is a management key (mk_). Pings need an ingest key (ck_)."
            return 1
        fi

        if [[ -n "$HELLOCRON_API_KEY" ]]; then
            curl_opts+=(-H "Authorization: Bearer $HELLOCRON_API_KEY")
        else
            log "debug" "No API key - sending request without authentication"
        fi

        if [[ -n "$data" && ("$method" == "POST" || "$method" == "PUT") ]]; then
            curl_opts+=(--data "$data")
        fi

        local http_code
        http_code=$(curl "${curl_opts[@]}" "$url" 2>/dev/null)

        if [[ "$http_code" == 2* ]]; then
            return 0
        fi

        log "error" "API communication error (HTTP: ${http_code:-no connection})"
        return 1

    elif [[ "$HTTP_TOOL" == "wget" ]]; then
        local wget_opts=(
            -q
            -O /dev/null
            --tries=1
            --timeout="$DEFAULT_TIMEOUT"
            --header="Content-Type: application/json"
        )

        if [[ "$ALLOW_INSECURE" == "true" ]]; then
            log "warn" "⚠️  WARNING: SSL verification disabled (--no-check-certificate). This is DANGEROUS!"
            wget_opts+=(--no-check-certificate)
        fi

        if [[ -n "$HELLOCRON_API_KEY" ]]; then
            wget_opts+=(--header="Authorization: Bearer $HELLOCRON_API_KEY")
        else
            log "debug" "No API key - sending request without authentication"
        fi

        if [[ -n "$data" && ("$method" == "POST" || "$method" == "PUT") ]]; then
            wget_opts+=(--post-data="$data")
        fi

        if wget "${wget_opts[@]}" "$url" 2>/dev/null; then
            return 0
        fi

        log "error" "API communication error (wget)"
        return 1
    fi

    log "debug" "No HTTP tool (curl/wget) - skipping API request"
    return 1
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null ||
    python -c "import uuid; print(uuid.uuid4())" 2>/dev/null ||
    (date +%s%N | md5sum | head -c 32)
}

parse_tags() {
    local tags_arg="$1"
    local tags_json="["

    if [[ -n "$tags_arg" ]]; then
        IFS=',' read -ra TAG_ARRAY <<< "$tags_arg"

        local first=true
        for tag in "${TAG_ARRAY[@]}"; do
            tag=$(echo "$tag" | xargs)

            if [[ "$first" != "true" ]]; then
                tags_json="${tags_json},"
            fi

            tags_json="${tags_json}\"$(json_escape "$tag")\""
            first=false
        done
    fi

    tags_json="${tags_json}]"

    echo "$tags_json"
}

is_running_from_cron() {
    local ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo "1")
    local pname=""
    if command -v ps >/dev/null 2>&1; then
        pname=$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ' || echo "unknown")
    else
        pname="unknown"
    fi

    if [[ "$pname" == *"cron"* ]]; then
        return 0
    fi

    if [[ "$TERM" == "dumb" ]]; then
        return 0
    fi

    if ! tty -s 2>/dev/null && command -v ps >/dev/null 2>&1 && [[ "$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ' || echo "1")" == "1" ]]; then
        return 0
    fi

    return 1
}

get_scheduled_time() {
    local current_time=$(date +%s)

    if ! is_running_from_cron; then
        echo "$current_time"
        return
    fi

    local scheduled_time=$(( current_time - (current_time % 60) ))

    echo "$scheduled_time"
}

get_timezone() {
    if [[ -f "/etc/timezone" ]]; then
        timezone=$(cat /etc/timezone 2>/dev/null)
        if [[ -n "$timezone" ]]; then
            echo "$timezone"
            return 0
        fi
    fi

    if [[ -L "/etc/localtime" ]]; then
        timezone=$(readlink /etc/localtime | sed 's/^.*zoneinfo\///')
        if [[ -n "$timezone" ]]; then
            echo "$timezone"
            return 0
        fi
    fi

    timezone=$(date +%Z 2>/dev/null)
    if [[ -n "$timezone" ]]; then
        full_tz=$(date +%:z 2>/dev/null)
        if [[ -n "$full_tz" ]]; then
            echo "UTC${full_tz}"
            return 0
        fi
        echo "$timezone"
        return 0
    fi

    echo "UTC"
    return 0
}

measure_execution() {
    local start_time=$SECONDS
    local unique_id=$(generate_uuid)
    local monitor_name="$1"
    local tags="$2"
    local project="$3"
    local cmd="${@:4}"
    local exit_code
    local error_code=""

    umask 077
    # stdout and stderr are captured separately so each can be handed back on its
    # own stream once the command finishes. Swallowing them would break a crontab
    # line that appends to a log file, and cron's own mail on failure.
    local out_file err_file
    out_file=$(mktemp 2>/dev/null) || out_file=/dev/null
    err_file=$(mktemp 2>/dev/null) || err_file=/dev/null

    local run_source=$(detect_run_source)
    log "debug" "Detected run source: $run_source"

    local cron_schedule=""
    if [[ "$run_source" == "cron" ]]; then
        cron_schedule=$(get_cron_schedule "$monitor_name")
        if [[ $? -eq 0 && -n "$cron_schedule" ]]; then
            log "info" "Detected cron schedule: $cron_schedule"
        else
            log "debug" "No cron schedule detected for monitor: $monitor_name"
        fi
    fi

    local timezone=$(get_timezone)
    log "debug" "Timezone: $timezone"

    log "info" "Starting job '$monitor_name' (ID: $unique_id, source: $run_source)"

    send_ping "$monitor_name" "run" "$unique_id" "0" "0" "" "$tags" "$project" "$run_source" "$cron_schedule" "$timezone" || true

    set +e
    "${@:4}" > "$out_file" 2> "$err_file"
    exit_code=$?
    set -e

    # Give the output back to whoever called us, on the stream it came from.
    if [[ "$out_file" != "/dev/null" && -s "$out_file" ]]; then
        cat "$out_file"
    fi
    if [[ "$err_file" != "/dev/null" && -s "$err_file" ]]; then
        cat "$err_file" >&2
    fi

    # The ping carries both streams, stdout first.
    local captured=""
    captured=$(cat "$out_file" "$err_file" 2>/dev/null)

    local duration=$((SECONDS - start_time))

    log "debug" "Job '$monitor_name' finished with code: $exit_code (duration: ${duration}s)"

    if [[ $exit_code -eq 0 ]]; then
        local raw_success_output="$captured"
        local success_output=""
        if [[ -n "$raw_success_output" ]]; then
            success_output=$(truncate_output "$raw_success_output" "$MAX_ERROR_OUTPUT_SIZE")
        fi
        send_ping "$monitor_name" "complete" "$unique_id" "$duration" "0" "" "$tags" "$project" "$run_source" "$cron_schedule" "$timezone" "$success_output" || true
        log "info" "Job '$monitor_name' completed successfully (duration: ${duration}s)"
    else
        local raw_error_output="$captured"

        local error_output=$(truncate_output "$raw_error_output" "$MAX_ERROR_OUTPUT_SIZE")

        case $exit_code in
            124)
                error_code="Timed out"
                ;;
            *)
                if [ "$exit_code" -gt 128 ] 2>/dev/null && [ "$exit_code" -le 192 ] 2>/dev/null; then
                    error_code="Terminated by signal $((exit_code - 128))"
                fi
                ;;
        esac

        send_ping "$monitor_name" "fail" "$unique_id" "$duration" "$exit_code" "$error_code" "$tags" "$project" "$run_source" "$cron_schedule" "$timezone" "$error_output" || true
        log "error" "Job '$monitor_name' failed (code: $exit_code, duration: ${duration}s)"
    fi

    [[ "$out_file" != "/dev/null" ]] && rm -f "$out_file"
    [[ "$err_file" != "/dev/null" ]] && rm -f "$err_file"

    return $exit_code
}

send_ping() {
    local monitor="$1"
    local status="$2"
    local unique_id="$3"
    local duration="${4:-0}"
    local exit_code="${5:-0}"
    local error="${6:-}"
    local tags_arg="${7:-}"
    local project="${8:-$DEFAULT_PROJECT}"
    local run_source="${9:-shell}"
    local cron_schedule="${10:-}"
    local timezone="${11:-$(get_timezone)}"
    local error_output="${12:-}"
    local timeout_seconds="${13:-}"

    if [[ "$TELEMETRY_ENABLED" != "true" ]]; then
        log "debug" "Telemetry disabled, skipping ping '$status' for '$monitor'"
        return 0
    fi

    local hostname=$(resolve_hostname)
    local timestamp=$(date -u +%s)

    local tags_json=$(parse_tags "$tags_arg")

    local ping_data
    ping_data=$(printf '{"event_type":"ping","monitor":"%s","status":"%s","unique_id":"%s","duration":%s,"exit_code":%s,"host":"%s","timestamp":%s,"received_at":%s,"timezone":"%s","run_source":"%s","tags":%s' \
        "$(json_escape "$monitor")" \
        "$(json_escape "$status")" \
        "$(json_escape "$unique_id")" \
        "$(json_number "$duration")" \
        "$(json_number "$exit_code")" \
        "$(json_escape "$hostname")" \
        "$(json_number "$timestamp")" \
        "$(json_number "$timestamp")" \
        "$(json_escape "$timezone")" \
        "$(json_escape "$run_source")" \
        "$tags_json")

    if [[ "$run_source" == "cron" && -n "$cron_schedule" ]]; then
        ping_data+=",\"cron_schedule\":\"$(json_escape "$cron_schedule")\""
    fi

    if [[ -n "$project" ]]; then
        ping_data+=",\"project\":\"$(json_escape "$project")\""
    fi

    if [[ -n "$error" ]]; then
        ping_data+=",\"error\":\"$(json_escape "$error")\""
    fi

    if [[ -n "$error_output" ]]; then
        ping_data+=",\"error_output\":\"$(json_escape "$error_output")\""
    fi

    if [[ -n "$timeout_seconds" ]]; then
        ping_data+=",\"timeout_seconds\":$(json_number "$timeout_seconds")"
    fi

    ping_data+="}"

    log "debug" "Sending ping '$status' for monitor '$monitor' (${#ping_data} bytes, source: $run_source)"
    if [[ "$run_source" == "cron" && -n "$cron_schedule" ]]; then
        log "debug" "Cron schedule: $cron_schedule"
    fi

    local result
    result=$(api_request "POST" "$API_PING_ENDPOINT" "$ping_data" 2>&1)
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        log "warn" "Failed to send ping to API"
        return 1
    fi

    log "debug" "Ping '$status' for '$monitor' sent successfully"
    return 0
}

send_ping_with_error_output() {
    send_ping "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}"
}

cmd_ping() {
    local monitor_name=""
    local state=""
    local message=""
    local tags=""
    local project="$DEFAULT_PROJECT"
    local run_source=""
    local cron_schedule=""
    local timezone=""
    local timeout_seconds=""

    if [[ $# -lt 2 ]]; then
        log "error" "Missing required parameters"
        echo "Usage: $0 ping <monitor_name> <state> [--tags <tags>] [--project <project>] [--run-source <source>] [--cron-schedule <schedule>] [--timezone <tz>] [--timeout <seconds>] [message]"
        echo "State: run, complete, fail, skip"
        echo "Source: cron, systemd, shell, interactive_shell, ssh, jenkins, docker, ..."
        echo "Timeout: maximum execution time in seconds (default: 30s)"
        return 1
    fi

    monitor_name="$1"
    state="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tags)
                tags="$2"
                shift 2
                ;;
            --project)
                project="$2"
                shift 2
                ;;
            --run-source)
                run_source="$2"
                shift 2
                ;;
            --cron-schedule)
                cron_schedule="$2"
                shift 2
                ;;
            --timezone)
                timezone="$2"
                shift 2
                ;;
            --timeout)
                timeout_seconds="$2"
                shift 2
                ;;
            *)
                message="$*"
                break
                ;;
        esac
    done

    if [[ ! "$state" =~ ^(run|complete|fail|skip)$ ]]; then
        log "error" "Invalid state. Allowed: run, complete, fail, skip"
        return 1
    fi

    if [[ -z "$run_source" ]]; then
        run_source=$(detect_run_source)
        log "debug" "Detected run source: $run_source"
    fi

    if [[ "$run_source" == "cron" && -z "$cron_schedule" ]]; then
        cron_schedule=$(get_cron_schedule "$monitor_name")
        if [[ $? -eq 0 && -n "$cron_schedule" ]]; then
            log "debug" "Detected cron schedule: $cron_schedule"
        fi
    fi

    if [[ -z "$timezone" ]]; then
        timezone=$(get_timezone)
        log "debug" "Detected timezone: $timezone"
    fi

    local unique_id=$(generate_uuid)

    if send_ping "$monitor_name" "$state" "$unique_id" "0" "0" "$message" "$tags" "$project" "$run_source" "$cron_schedule" "$timezone" "" "$timeout_seconds"; then
        log "info" "Ping '$state' for monitor '$monitor_name' sent successfully (source: $run_source, timezone: $timezone)"
        if [[ "$run_source" == "cron" && -n "$cron_schedule" ]]; then
            log "info" "Cron schedule: $cron_schedule"
        fi
        if [[ -n "$timeout_seconds" ]]; then
            log "info" "Timeout: ${timeout_seconds}s"
        fi
        return 0
    else
        log "error" "Failed to send ping for monitor '$monitor_name'"
        return 1
    fi
}

detect_run_source() {

    if is_running_from_cron; then
        echo "cron"
        return 0
    fi

    if command -v ps >/dev/null 2>&1 && ps -p $PPID -o comm= 2>/dev/null | grep -q "systemd"; then
        echo "systemd"
        return 0
    fi

    if command -v ps >/dev/null 2>&1 && ps -p $PPID -o comm= 2>/dev/null | grep -q "init"; then
        echo "init"
        return 0
    fi

    if command -v ps >/dev/null 2>&1 && ps -p $PPID -o comm= 2>/dev/null | grep -q "sshd"; then
        echo "ssh"
        return 0
    fi

    if [[ -n "$JENKINS_HOME" ]]; then
        echo "jenkins"
        return 0
    fi

    if [[ -n "$GITLAB_CI" ]]; then
        echo "gitlab_ci"
        return 0
    fi

    if [[ -n "$GITHUB_ACTIONS" ]]; then
        echo "github_actions"
        return 0
    fi

    if [[ -n "$TRAVIS" ]]; then
        echo "travis_ci"
        return 0
    fi

    if [[ -n "$CIRCLECI" ]]; then
        echo "circle_ci"
        return 0
    fi

    if [[ -n "$DOCKER_CONTAINER" || -f "/.dockerenv" ]]; then
        echo "docker"
        return 0
    fi

    if [[ -t 0 && -t 1 && -t 2 ]]; then
        echo "interactive_shell"
        return 0
    fi

    echo "shell"
    return 0
}

# Reconcile the account with a bundle file (config as code).
#
# The client deliberately does not parse the JSON report: jq is not a dependency
# (curl or wget is all this script needs). The server's response is printed
# as-is and the HTTP status decides the exit code, which is what CI needs.
cmd_apply() {
    local file=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--file)
                if [[ -z "$2" ]]; then
                    log "error" "Option $1 requires a file path"
                    return 1
                fi
                file="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 apply -f <bundle.json> [--dry-run]"
                echo ""
                echo "Options:"
                echo "  -f, --file <path>   Bundle file to apply (required)"
                echo "  --dry-run           Report what would change without writing"
                echo ""
                echo "The management key comes from HELLOCRON_MANAGEMENT_KEY or"
                echo "$MANAGEMENT_CONFIG_FILE. Apply never deletes monitors:"
                echo "ones missing from the bundle are reported as orphaned."
                return 0
                ;;
            *)
                log "error" "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$file" ]]; then
        log "error" "Missing bundle file. Usage: $0 apply -f <bundle.json> [--dry-run]"
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        log "error" "Bundle file not found: $file"
        return 1
    fi

    require_management_key || return 1

    local path="/api/v1/monitors/apply"
    [[ "$dry_run" == "true" ]] && path="${path}?dry_run=true"

    local response
    response=$(management_request "POST" "$path" "$file")
    local ok=$?

    [[ -n "$response" ]] && echo "$response"

    if [[ $ok -ne 0 ]]; then
        log "error" "Apply failed (HTTP: ${MANAGEMENT_HTTP_CODE:-no connection})"
        return 1
    fi

    return 0
}

# Export the whole account as a bundle that apply() accepts unchanged.
cmd_export() {
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                if [[ -z "$2" ]]; then
                    log "error" "Option $1 requires a file path"
                    return 1
                fi
                output="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 export [-o <bundle.json>]"
                echo ""
                echo "Options:"
                echo "  -o, --output <path>   Write the bundle to a file (default: stdout)"
                return 0
                ;;
            *)
                log "error" "Unknown option: $1"
                return 1
                ;;
        esac
    done

    require_management_key || return 1

    local response
    response=$(management_request "GET" "/api/v1/monitors/export" "")
    local ok=$?

    if [[ $ok -ne 0 ]]; then
        [[ -n "$response" ]] && echo "$response" >&2
        log "error" "Export failed (HTTP: ${MANAGEMENT_HTTP_CODE:-no connection})"
        return 1
    fi

    if [[ -n "$output" ]]; then
        umask 077
        printf '%s\n' "$response" > "$output" || {
            log "error" "Cannot write to $output"
            return 1
        }
        log "warn" "Bundle written to $output"
    else
        printf '%s\n' "$response"
    fi

    return 0
}

cmd_help() {
    header

    echo -e "\033[1;33mCurrent config file:\033[0m $CONFIG_FILE"
    echo ""
    echo -e "\033[1;32mUsage:\033[0m"
    echo "  $0 [--config <path>] [-v|--verbose] <command> [options]"
    echo ""
    echo -e "\033[1;32mCommands:\033[0m"
    echo "  run <monitor_name> [--tags <tags>] [--project <project>] [--config <path>] <command...>   Run a command and monitor its execution"
    echo "  ping <monitor_name> <state> [--tags <tags>] [--project <project>] [message]   Send a ping with the given state (run/complete/fail/skip)"
    echo "  discover                                           Detect cron jobs and generate monitoring config"
    echo "  apply -f <bundle.json> [--dry-run]                 Reconcile your monitors with a bundle file (config as code)"
    echo "  export [-o <bundle.json>]                          Export all monitors as a bundle file"
    echo "  configure [--api-key <key>] [--project <name>]     Save your ingest key (asks for it when not given)"
    echo "  configure --management-key                         Save the management key used by apply and export"
    echo "  update [--check]                                   Update the script to the latest version"
    echo "  doctor [--ping]                                    Check your setup (config, connectivity); --ping sends a test ping"
    echo "  help                                               Show this help"
    echo "  version                                            Show version information"
    echo ""
    echo -e "\033[1;32mGlobal options:\033[0m"
    echo "  --config <path>                                    Path to config file (default: $CONFIG_FILE)"
    echo "  -v, --verbose                                      Enable verbose [INFO] and [DEBUG] output"
    echo ""
    echo -e "\033[1;32mCommand options:\033[0m"
    echo "  --tags <tag1,tag2,...>                             Comma-separated list of tags"
    echo "  --project <project_name>                           Project the job belongs to"
    echo ""
    echo -e "\033[1;33m⚠️  SECURITY NOTES:\033[0m"
    echo "  • Save your ingest key before use: $0 configure"
    echo "  • Use HTTPS instead of HTTP to protect your data"
    echo "  • The API key is stored in plaintext in $CONFIG_FILE"
    echo "  • apply/export need the MANAGEMENT key (mk_), kept apart from the ingest key:"
    echo "    HELLOCRON_MANAGEMENT_KEY, or $MANAGEMENT_CONFIG_FILE"
    echo "  • Never copy the management key to monitored servers - it can delete monitors"
    echo "  • Run ONLY trusted commands via 'run' - they are executed directly"
    echo "  • SSL verification is ENABLED by default (recommended)"
    echo ""
    echo "Examples:"
    echo "  $0 run backup-database --tags production,nightly --project backend pg_dump -U postgres database > /backups/db.sql"
    echo "  $0 --config /etc/hellocron/prod.conf run backup-database --tags production pg_dump database"
    echo "  $0 run backup-database --config /tmp/test.conf --tags test pg_dump database"
    echo "  $0 ping daily-backup complete --tags cron,backup --project system"
    echo "  $0 discover --crontab /etc/crontab --output /etc/hellocron-client/crontab.conf"
    echo "  $0 export -o monitors.json"
    echo "  $0 apply -f monitors.json --dry-run"
    echo "  $0 configure"
    echo ""
    echo "More information on the project website."
}

doctor_http_code() {
    local url="$1"
    if [[ "$HTTP_TOOL" == "curl" ]]; then
        curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$DEFAULT_PING_TIMEOUT" --max-time "$DEFAULT_TIMEOUT" "$url" 2>/dev/null
    elif [[ "$HTTP_TOOL" == "wget" ]]; then
        if wget -q -O /dev/null --tries=1 --timeout="$DEFAULT_TIMEOUT" "$url" 2>/dev/null; then
            echo "200"
        else
            echo "000"
        fi
    else
        echo "000"
    fi
}

cmd_doctor() {
    local send_test_ping=false
    local problems=0
    local warnings=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ping) send_test_ping=true; shift ;;
            *)
                log "error" "Unknown option: $1"
                echo "Usage: $0 doctor [--ping]"
                return 1
                ;;
        esac
    done

    d_ok()   { echo -e "\033[0;32m✓\033[0m $1"; }
    d_warn() { echo -e "\033[0;33m!\033[0m $1"; warnings=$((warnings + 1)); }
    d_fail() { echo -e "\033[0;31m✗\033[0m $1"; problems=$((problems + 1)); }

    header
    echo ""

    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        d_ok "bash ${BASH_VERSION%%(*}"
    else
        d_warn "bash ${BASH_VERSION%%(*} is old (4+ recommended)"
    fi

    detect_http_tool
    if [[ -n "$HTTP_TOOL" ]]; then
        d_ok "HTTP tool: $HTTP_TOOL"
    else
        d_fail "No HTTP tool found (install curl or wget) - pings cannot be sent"
    fi

    local config_in_use=""
    if [[ -f "$CONFIG_FILE" ]]; then
        config_in_use="$CONFIG_FILE"
    elif [[ -f "$LEGACY_CONFIG_FILE" ]]; then
        config_in_use="$LEGACY_CONFIG_FILE"
        d_warn "Using legacy JSON config ($LEGACY_CONFIG_FILE) - run '$0 configure' to migrate to $CONFIG_FILE"
    fi

    if [[ -n "$config_in_use" ]]; then
        d_ok "Config file: $config_in_use"
        local perms
        perms=$(stat -c '%a' "$config_in_use" 2>/dev/null || stat -f '%Lp' "$config_in_use" 2>/dev/null)
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
            d_ok "Config permissions: $perms"
        else
            d_warn "Config permissions are ${perms:-unknown} (recommended: chmod 600 $config_in_use)"
        fi
    else
        d_fail "No config file found - run: $0 configure"
    fi

    # Management credentials are optional - only report on them when present.
    load_management_config
    if [[ -f "$MANAGEMENT_CONFIG_FILE" ]]; then
        local mgmt_perms
        mgmt_perms=$(stat -c '%a' "$MANAGEMENT_CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$MANAGEMENT_CONFIG_FILE" 2>/dev/null)
        if [[ "$mgmt_perms" == "600" || "$mgmt_perms" == "400" ]]; then
            d_ok "Management config: $MANAGEMENT_CONFIG_FILE ($mgmt_perms)"
        else
            d_warn "Management config permissions are ${mgmt_perms:-unknown} (run: chmod 600 $MANAGEMENT_CONFIG_FILE)"
        fi
    fi

    if [[ -n "$HELLOCRON_MANAGEMENT_KEY" ]]; then
        if [[ "$HELLOCRON_MANAGEMENT_KEY" == ck_* ]]; then
            d_fail "Management key is an ingest key (ck_) - apply/export will refuse to run"
        else
            d_ok "Management key: set (${#HELLOCRON_MANAGEMENT_KEY} chars), panel: $PANEL_URL"
        fi
    fi

    if [[ "$HELLOCRON_API_KEY" == mk_* ]]; then
        d_fail "api_key is a management key (mk_) - pings need an ingest key (ck_)"
    fi

    if [[ -z "$API_URL" ]]; then
        d_fail "API URL is empty"
    elif [[ "$API_URL" =~ ^http:// ]]; then
        d_warn "API URL uses insecure HTTP: $API_URL"
    else
        d_ok "API URL: $API_URL"
    fi

    d_ok "Reported host: $(resolve_hostname)"

    if [[ -n "$HELLOCRON_API_KEY" ]]; then
        d_ok "API key: set (${#HELLOCRON_API_KEY} chars)"
    else
        d_fail "API key is not set - run: $0 configure"
    fi

    if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
        d_ok "Telemetry: enabled"
    else
        d_warn "Telemetry: disabled (pings will not be sent)"
    fi

    local tmp_probe
    if tmp_probe=$(mktemp 2>/dev/null); then
        rm -f "$tmp_probe"
        d_ok "Temp directory writable"
    else
        d_warn "mktemp failed - 'run' will work but command output will not be captured"
    fi

    if [[ -n "$HTTP_TOOL" && -n "$API_URL" ]]; then
        local health_code
        health_code=$(doctor_http_code "${API_URL}/health")
        if [[ "$health_code" == 2* ]]; then
            d_ok "API reachable: ${API_URL}/health (HTTP $health_code)"
        else
            d_fail "API not reachable: ${API_URL}/health (HTTP ${health_code:-000})"
        fi
    fi

    if command -v crontab >/dev/null 2>&1; then
        local cron_count
        cron_count=$(crontab -l 2>/dev/null | grep -cvE '^[[:space:]]*(#|$)' || true)
        d_ok "crontab available (${cron_count:-0} active entries)"
    else
        d_warn "crontab command not found - 'discover' and schedule detection will not work"
    fi

    if [[ "$send_test_ping" == "true" ]]; then
        if send_ping "doctor-selftest" "skip" "$(generate_uuid)" "0" "0" "doctor self-test" >/dev/null 2>&1; then
            d_ok "Test ping sent (monitor: doctor-selftest, state: skip)"
        else
            d_fail "Test ping failed - check API URL, key and connectivity"
        fi
    fi

    echo ""
    if [[ $problems -eq 0 ]]; then
        echo -e "\033[0;32mResult: OK\033[0m ($warnings warning(s))"
        return 0
    fi

    echo -e "\033[0;31mResult: $problems problem(s) found\033[0m ($warnings warning(s))"
    return 1
}

cmd_update() {
    local check_only=false
    local update_url="https://hellocron.com/hellocron.sh"
    local checksum_url="https://hellocron.com/hellocron.sh.sha256"
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                check_only=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 update [--check]"
                echo ""
                echo "  --check    Check for a new version without installing"
                return 0
                ;;
            *)
                log "error" "Unknown option: $1"
                return 1
                ;;
        esac
    done

    header

    for cmd in curl sha256sum bash; do
        if ! command -v "$cmd" &>/dev/null; then
            log "error" "Missing required tool: $cmd"
            return 1
        fi
    done

    if [[ "$update_url" != https://* ]]; then
        log "error" "Update URL must use HTTPS"
        return 1
    fi

    echo "Checking for updates..."

    local remote_checksum
    remote_checksum=$(curl --silent --fail --max-time 10 --location "$checksum_url" 2>/dev/null) || {
        log "error" "Cannot download checksum file from: $checksum_url"
        return 1
    }

    local remote_hash
    remote_hash=$(echo "$remote_checksum" | awk '{print $1}')
    if [[ ! "$remote_hash" =~ ^[a-f0-9]{64}$ ]]; then
        log "error" "Invalid checksum format: $remote_hash"
        return 1
    fi

    local current_hash
    current_hash=$(sha256sum "$script_path" | awk '{print $1}')

    if [[ "$remote_hash" == "$current_hash" ]]; then
        echo -e "\033[0;32m✓ You have the latest version (SHA256: ${current_hash:0:12}...)\033[0m"
        return 0
    fi

    echo -e "\033[1;33m⚡ Update available\033[0m"
    echo "  Current: ${current_hash:0:12}..."
    echo "  New:     ${remote_hash:0:12}..."

    if [[ "$check_only" == "true" ]]; then
        echo ""
        echo "To install: $0 update"
        return 0
    fi

    umask 077
    local temp_file
    temp_file=$(mktemp)
    local backup_file="${script_path}.bak"

    echo "Downloading update..."
    if ! curl --silent --fail --max-time 30 --location "$update_url" -o "$temp_file" 2>/dev/null; then
        log "error" "Cannot download the update"
        rm -f "$temp_file"
        return 1
    fi

    local downloaded_hash
    downloaded_hash=$(sha256sum "$temp_file" | awk '{print $1}')
    if [[ "$downloaded_hash" != "$remote_hash" ]]; then
        log "error" "Checksum verification failed - the file may have been modified in transit"
        log "error" "  Expected: $remote_hash"
        log "error" "  Received:  $downloaded_hash"
        rm -f "$temp_file"
        return 1
    fi

    if ! bash -n "$temp_file" 2>/dev/null; then
        log "error" "Downloaded file has bash syntax errors - update aborted"
        rm -f "$temp_file"
        return 1
    fi

    if ! grep -q "HelloCronClient" "$temp_file" 2>/dev/null; then
        log "error" "Downloaded file does not look like a hellocron script - update aborted"
        rm -f "$temp_file"
        return 1
    fi

    if ! cp "$script_path" "$backup_file" 2>/dev/null; then
        log "warn" "Cannot create backup at $backup_file (permission denied?)"
    else
        echo "  Backup: $backup_file"
    fi

    local current_perms
    current_perms=$(stat -c '%a' "$script_path" 2>/dev/null || echo "755")
    if ! mv "$temp_file" "$script_path" 2>/dev/null; then
        log "error" "Cannot replace $script_path - check permissions"
        rm -f "$temp_file"
        return 1
    fi
    chmod "$current_perms" "$script_path"

    echo -e "\033[0;32m✓ Update completed successfully\033[0m"
    echo "  Installed: ${remote_hash:0:12}..."
    echo "  Backup: $backup_file"
    return 0
}

cmd_version() {
    header
    echo "HelloCronClient ${VERSION_TAG} (${VERSION_DATE})"
}

cmd_configure() {
    if [[ "${1:-}" == "--management-key" ]]; then
        cmd_configure_management_key
        return $?
    fi

    local advanced=false
    local arg_key="" arg_project="" arg_url=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-key)  arg_key="$2"; shift 2 ;;
            --project)  arg_project="$2"; shift 2 ;;
            --api-url)  arg_url="$2"; shift 2 ;;
            --advanced) advanced=true; shift ;;
            --help|-h)
                echo "Usage: $0 configure [options]"
                echo ""
                echo "Options:"
                echo "  --api-key <key>    Save the ingest key without prompting (provisioning, CI)"
                echo "  --project <name>   Default project for every ping sent from this host"
                echo "  --advanced         Also ask for the API URL and ping endpoint"
                echo "  --api-url <url>    Point the client at another API (self-hosted, staging)"
                echo "  --management-key   Configure the management key used by apply/export"
                return 0
                ;;
            *) log "error" "Unknown option: $1 (see: $0 configure --help)"; return 1 ;;
        esac
    done

    [[ -n "$arg_url" ]] && API_URL="$arg_url"
    [[ -n "$arg_project" ]] && DEFAULT_PROJECT="$arg_project"

    # Non-interactive path: everything needed came in on the command line.
    if [[ -n "$arg_key" ]]; then
        if [[ "$arg_key" == mk_* ]]; then
            log "error" "That is a management key (mk_). Pings need an ingest key (ck_)."
            return 1
        fi
        HELLOCRON_API_KEY="$arg_key"
        save_config
        return 0
    fi

    header
    echo -e "\033[1;33mConfiguration file:\033[0m $CONFIG_FILE"
    echo ""
    echo "The ingest key starts with ck_ and is created in the panel:"
    echo "  ${PANEL_URL}  ->  Settings  ->  API keys"
    echo "It can only send pings. The management key (mk_) belongs on your"
    echo "workstation or in CI, never on a monitored host."
    echo ""

    local shown=""
    [[ -n "$HELLOCRON_API_KEY" ]] && shown=" [$(mask_key "$HELLOCRON_API_KEY")]"
    read -t 300 -p "Ingest API key${shown}: " new_api_key || { log "error" "Timeout - no response"; return 1; }
    new_api_key="${new_api_key:-$HELLOCRON_API_KEY}"

    if [[ -z "$new_api_key" ]]; then
        log "error" "No API key given, nothing was saved"
        return 1
    fi
    if [[ "$new_api_key" == mk_* ]]; then
        log "error" "That is a management key (mk_). Pings need an ingest key (ck_)."
        return 1
    fi
    HELLOCRON_API_KEY="$new_api_key"

    read -t 300 -p "Default project (optional) [${DEFAULT_PROJECT}]: " new_project || { log "error" "Timeout - no response"; return 1; }
    DEFAULT_PROJECT="${new_project:-$DEFAULT_PROJECT}"

    # The API lives at a fixed address; only self-hosted and staging need this.
    if [[ "$advanced" == "true" ]]; then
        read -t 300 -p "API URL [$API_URL]: " new_api_url || { log "error" "Timeout - no response"; return 1; }
        API_URL="${new_api_url:-$API_URL}"
        read -t 300 -p "API ping endpoint [$API_PING_ENDPOINT]: " new_endpoint || { log "error" "Timeout - no response"; return 1; }
        API_PING_ENDPOINT="${new_endpoint:-$API_PING_ENDPOINT}"
    fi

    save_config

    echo ""
    echo "Testing the connection to $API_URL ..."
    if api_request "GET" "/health" > /dev/null; then
        log "info" "API connection successful"
    else
        log "warn" "Could not reach the API. Run '$0 doctor' for details."
    fi
}

cmd_configure_management_key() {
    header
    echo "Management API configuration (config as code)"
    echo "---------------------------------------------"
    echo ""
    echo -e "\033[1;33m⚠️  The management key can create, change and DELETE monitors,\033[0m"
    echo -e "\033[1;33m   and deleting a ping monitor also removes its event history.\033[0m"
    echo -e "\033[1;33m   It is stored in plaintext in $MANAGEMENT_CONFIG_FILE (600).\033[0m"
    echo -e "\033[1;33m   Keep it on this machine - do not ship it to monitored servers.\033[0m"
    echo ""

    load_management_config

    local current_panel="$PANEL_URL"

    read -t 300 -p "Panel URL [$current_panel]: " new_panel || { log "error" "Timeout - no response"; return 1; }
    PANEL_URL=${new_panel:-$current_panel}

    local shown="not set"
    [[ -n "$HELLOCRON_MANAGEMENT_KEY" ]] && shown="${HELLOCRON_MANAGEMENT_KEY:0:6}..."

    read -t 300 -p "Management key (mk_...) [$shown]: " new_key || { log "error" "Timeout - no response"; return 1; }
    [[ -n "$new_key" ]] && HELLOCRON_MANAGEMENT_KEY="$new_key"

    if [[ -z "$HELLOCRON_MANAGEMENT_KEY" ]]; then
        log "error" "No key provided"
        return 1
    fi

    if [[ "$HELLOCRON_MANAGEMENT_KEY" == ck_* ]]; then
        log "error" "That is an ingest key (ck_). The management key starts with mk_."
        return 1
    fi

    save_management_config || return 1

    echo ""
    echo "Testing management API..."
    if management_request "GET" "/api/v1/monitors/export" "" > /dev/null; then
        echo "Connection successful. Try: $0 export"
    else
        log "warn" "Could not reach the management API (HTTP: ${MANAGEMENT_HTTP_CODE:-no connection})"
    fi
}

get_cron_schedule() {
    local monitor_name="$1"
    local cron_schedule=""
    local timezone=$(cat /etc/timezone 2>/dev/null || date +%Z)

    if ! is_running_from_cron; then
        log "debug" "Job is not running from cron"
        return 1
    fi

    log "debug" "Detecting cron schedule for monitor: $monitor_name"

    local ppid="1"
    if command -v ps >/dev/null 2>&1; then
        ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo "1")
    fi

    local script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    local script_name=$(basename "$script_path")

    if command -v crontab >/dev/null 2>&1; then
        local user_crontab=$(crontab -l 2>/dev/null)

        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]]; then
                continue
            fi

            if [[ "$line" == *"$script_name"* && "$line" == *"$monitor_name"* ]]; then
                if [[ "$line" =~ ^[[:space:]]*([*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+)[[:space:]]+ ]]; then
                    cron_schedule="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^[[:space:]]*(@[a-z]+)[[:space:]]+ ]]; then
                    cron_schedule="${BASH_REMATCH[1]}"
                fi

                break
            fi
        done <<< "$user_crontab"
    fi

    if [[ -z "$cron_schedule" ]]; then
        local system_crontab_files=("/etc/crontab" "/etc/cron.d/"*)

        for crontab_file in "${system_crontab_files[@]}"; do
            if [[ -f "$crontab_file" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]]; then
                        continue
                    fi

                    if [[ "$line" == *"$script_name"* && "$line" == *"$monitor_name"* ]]; then
                        if [[ "$line" =~ ^[[:space:]]*([*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+)[[:space:]]+ ]]; then
                            cron_schedule="${BASH_REMATCH[1]}"
                        elif [[ "$line" =~ ^[[:space:]]*(@[a-z]+)[[:space:]]+ ]]; then
                            cron_schedule="${BASH_REMATCH[1]}"
                        fi

                        break
                    fi
                done < "$crontab_file"

                if [[ -n "$cron_schedule" ]]; then
                    break
                fi
            fi
        done
    fi

    if [[ -z "$cron_schedule" ]]; then
        if [[ "$script_path" == "/etc/cron.hourly/"* ]]; then
            cron_schedule="@hourly"
        elif [[ "$script_path" == "/etc/cron.daily/"* ]]; then
            cron_schedule="@daily"
        elif [[ "$script_path" == "/etc/cron.weekly/"* ]]; then
            cron_schedule="@weekly"
        elif [[ "$script_path" == "/etc/cron.monthly/"* ]]; then
            cron_schedule="@monthly"
        fi
    fi

    if [[ -n "$cron_schedule" ]]; then
        echo "$cron_schedule"
        return 0
    fi

    return 1
}

cmd_run() {
    local monitor_name=""
    local tags=""
    local project="$DEFAULT_PROJECT"
    local custom_config=""

    if [[ $# -lt 1 ]]; then
        log "error" "Missing required parameters"
        echo "Usage: $0 run <monitor_name> [--tags <tags>] [--project <project>] [--config <path>] <command...>"
        return 1
    fi

    monitor_name="$1"
    shift

    while [[ $# -gt 0 && "$1" =~ ^-- ]]; do
        case "$1" in
            --tags)
                tags="$2"
                shift 2
                ;;
            --project)
                project="$2"
                shift 2
                ;;
            --config)
                custom_config="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -lt 1 ]]; then
        log "error" "No command to execute"
        echo "Usage: $0 run <monitor_name> [--tags <tags>] [--project <project>] [--config <path>] <command...>"
        return 1
    fi

    if [[ -n "$custom_config" ]]; then
        local original_config_file="$CONFIG_FILE"
        CONFIG_FILE="$custom_config"
        log "debug" "Using custom config file: $CONFIG_FILE"
        
        load_config
        
        measure_execution "$monitor_name" "$tags" "$project" "$@"
        local exit_code=$?
        
        CONFIG_FILE="$original_config_file"
        return $exit_code
    else
        measure_execution "$monitor_name" "$tags" "$project" "$@"
        return $?
    fi
}

check_cron_entry_exists() {
    local entry="$1"
    local existing_crontab=""
    
    if existing_crontab=$(crontab -l 2>/dev/null); then
        local normalized_entry=$(echo "$entry" | sed 's/[[:space:]]\+/ /g' | xargs)
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ ]]; then
                continue
            fi
            
            local normalized_line=$(echo "$line" | sed 's/[[:space:]]\+/ /g' | xargs)
            
            if [[ "$normalized_line" == "$normalized_entry" ]]; then
                return 0
            fi
            
            if [[ "$line" == *"hellocron.sh run"* ]]; then
                local monitor_from_line=$(echo "$line" | sed -n 's/.*hellocron\.sh run \([^ ]*\).*/\1/p')
                local monitor_from_entry=$(echo "$entry" | sed -n 's/.*hellocron\.sh run \([^ ]*\).*/\1/p')
                
                if [[ -n "$monitor_from_line" && "$monitor_from_line" == "$monitor_from_entry" ]]; then
                    return 0
                fi
            fi
        done <<< "$existing_crontab"
    fi
    
    return 1
}

# ── Monitor naming ──────────────────────────────────────────────────────────
# The API accepts [A-Za-z0-9_-]{1,64} and rejects anything else, so every name
# derived from a crontab line goes through sanitize_monitor_name first. A dot
# from a script filename used to be enough to make every ping fail.
sanitize_monitor_name() {
    local out
    out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-*//; s/-*$//')
    out="${out:0:57}"
    printf '%s' "${out%%-}"
}

# Turns a cron command into a name a human recognises in the dashboard.
# A URL first, because that is what most cron one-liners are, then the first
# real program on the line, with its target appended when the program name
# alone says nothing (find, tar, php artisan and friends).
derive_monitor_name() {
    local cmd="$1"
    local url host site path name=""

    url=$(printf '%s' "$cmd" | grep -oE 'https?://[^ "'"'"'`)]+' | head -n1)

    if [[ -n "$url" ]]; then
        host=${url#*://}
        path=${host#*/}
        [[ "$path" == "$host" ]] && path=""
        host=${host%%/*}
        host=${host%%\?*}
        host=${host##*@}
        host=${host%%:*}
        host=${host#www.}
        path=${path%%\?*}
        path=${path%%#*}

        # panel.fakturex.pl -> fakturex, amkapp.pl -> amkapp,
        # example.co.uk -> example (two-level public suffixes)
        site="$host"
        if [[ "$host" == *.* ]]; then
            local -a labels=()
            IFS='.' read -ra labels <<< "$host"
            local n=${#labels[@]}
            site="${labels[n-2]}"
            if [[ $n -ge 3 ]]; then
                case "${labels[n-2]}" in
                    co|com|net|org|gov|edu|ac|biz|info) site="${labels[n-3]}" ;;
                esac
            fi
        fi

        local -a segs=()
        local seg parts=""
        IFS='/' read -ra segs <<< "$path"
        for seg in "${segs[@]}"; do
            case "$seg" in
                ''|cron|crons|cronjob|cronjobs|api|v1|v2|index|index.php|run|task|tasks|job|jobs) continue ;;
            esac
            seg=${seg%.php}; seg=${seg%.html}
            parts="${parts}-${seg}"
        done
        name="${site}${parts}"
        # A bare hostname is ambiguous when several jobs hit the same site.
        [[ -z "$parts" && "$host" != "$site" ]] && name="${site}-${host%%.*}"
    else
        local -a words=()
        local w base prog="" target=""
        read -ra words <<< "$cmd"
        for w in "${words[@]}"; do
            # environment assignments and flags are never the program
            [[ "$w" == -* ]] && continue
            [[ "$w" == *=* && "$w" != /* && "$w" != ./* ]] && continue
            base=${w##*/}
            base=${base%.sh}; base=${base%.bash}; base=${base%.php}
            base=${base%.py}; base=${base%.pl}; base=${base%.rb}; base=${base%.js}
            case "$base" in
                sudo|doas|env|nice|ionice|flock|timeout|chronic|setsid|nohup|xargs|time|bash|sh|dash|zsh|ksh|php|php[0-9]*|python|python[0-9]*|perl|ruby|node|npm|npx|docker|docker-compose|podman|kubectl|make)
                    continue ;;
            esac
            if [[ -z "$prog" ]]; then
                prog="$base"
                # These say nothing on their own, so keep looking for a target.
                case "$prog" in
                    find|rm|cp|mv|tar|rsync|gzip|zip|unzip|mysqldump|pg_dump|psql|mysql|git|composer|artisan|wp|drush|systemctl|service|bin)
                        continue ;;
                esac
                break
            fi
            # A short opaque token is a bundled flag (tar czf), not a target.
            if [[ "$w" != */* && "$w" != *.* && "$w" != *:* && ${#w} -le 4 ]]; then
                continue
            fi
            target=${w##*/}
            target=${target%.php}
            break
        done
        name="$prog"
        [[ -n "$target" ]] && name="${prog}-${target}"
    fi

    sanitize_monitor_name "$name"
}

cmd_discover() {
    local crontab_file=""
    local output_file=""
    local include_disabled=false
    local verbose=false
    local use_name_hash=false
    local host_prefix=false
    local default_project="$DEFAULT_PROJECT"
    local script_absolute_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")")
    local template="%s %s run %s %s"
    local discovered=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --crontab)
                crontab_file="$2"
                shift 2
                ;;
            --output)
                output_file="$2"
                shift 2
                ;;
            --include-disabled)
                include_disabled=true
                shift
                ;;
            --verbose|-v)
                verbose=true
                shift
                ;;
            --host-prefix)
                host_prefix=true
                shift
                ;;
            --use-name-hash)
                use_name_hash=true
                shift
                ;;
            --project)
                default_project="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 discover [options]"
                echo ""
                echo "Options:"
                echo "  --crontab <file>          Crontab file to analyze (default: current user crontab)"
                echo "  --output <file>           Output file (default: stdout)"
                echo "  --include-disabled        Include commented-out cron jobs"
                echo "  --verbose, -v             Show detailed information"
                echo "  --use-name-hash           Use a hash as the monitor name"
                echo "  --host-prefix             Prefix every name with this host, for the same crontab on many servers"
                echo "  --project <name>          Default project name for discovered jobs"
                echo "  --help, -h                Show this help"
                echo ""
                echo "Output colors:"
                echo "  Blue   - job already managed by hellocron.sh"
                echo "  Gray   - job already exists in crontab (not hellocron)"
                echo "  Orange - job to be added to crontab"
                return 0
                ;;
            *)
                log "error" "Unknown option: $1"
                return 1
                ;;
        esac
    done

    header

    log "info" "Discovering cron jobs..."

    umask 077

    local temp_file=$(mktemp)

    if [[ -z "$crontab_file" ]]; then
        if ! crontab -l &>/dev/null; then
            log "error" "Cannot access user crontab. Check whether you have any cron jobs."
            rm -f "$temp_file"
            return 1
        fi

        log "debug" "Using current user's crontab"
        local content=$(crontab -l)
    else
        if [[ ! -f "$crontab_file" ]]; then
            log "error" "Crontab file does not exist: $crontab_file"
            rm -f "$temp_file"
            return 1
        fi
        local content=$(cat "$crontab_file")
    fi

    # Names have to be unique inside one crontab. The short hash is only
    # appended when two lines derive the same name, so the common case stays
    # readable: fakturex-fcron, not curl-16f0fd.
    declare -A seen_names=()
    local MONITOR_NAME=""
    # Sets MONITOR_NAME instead of echoing it: command substitution runs in a
    # subshell, and the bookkeeping above has to survive from line to line.
    generate_monitor_name() {
        local cmd="$1"
        local name

        if [[ "$use_name_hash" == "true" ]]; then
            MONITOR_NAME=$(printf '%s' "$cmd" | md5sum | cut -d' ' -f1)
            return 0
        fi

        name=$(derive_monitor_name "$cmd")
        [[ -z "$name" ]] && name="job"

        # One crontab deployed to several servers needs one monitor per server;
        # the host is otherwise only visible on the individual events.
        if [[ "$host_prefix" == "true" ]]; then
            local short_host
            short_host=$(resolve_hostname)
            short_host=${short_host%%.*}
            short_host=$(sanitize_monitor_name "$short_host")
            [[ -n "$short_host" ]] && name="${short_host}-${name}"
        fi

        if [[ -n "${seen_names[$name]:-}" ]]; then
            name="${name}-$(printf '%s' "$cmd" | md5sum | cut -c1-6)"
        fi
        seen_names[$name]=1

        MONITOR_NAME="$name"
    }

    if [[ "$verbose" == "true" ]]; then
        log "debug" "Crontab contents:"
        echo "$content"
        echo "----------------------"
    fi

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*$ || ("$include_disabled" != "true" && "$line" =~ ^[[:space:]]*#) ]]; then
            continue
        fi

        if [[ "$include_disabled" == "true" && "$line" =~ ^[[:space:]]*# ]]; then
            line=$(echo "$line" | sed 's/^[[:space:]]*#[[:space:]]*//')
        fi

        if [[ "$verbose" == "true" ]]; then
            log "debug" "Analyzing line: $line"
        fi

        if [[ "$line" =~ ^[[:space:]]*([*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+[[:space:]]+[*0-9,-/]+)[[:space:]]+(.+) ]]; then
            local schedule="${BASH_REMATCH[1]}"
            local command="${BASH_REMATCH[2]}"

            command=$(echo "$command" | sed 's/[[:space:]]*#.*$//')

            if [[ "$command" == *"hellocron.sh run"* || "$command" == *"hellocron.sh ping"* || "$command" == *"hellocron run"* || "$command" == *"hellocron ping"* ]]; then
                if [[ "$verbose" == "true" ]]; then
                    log "debug" "Found hellocron entry: $command"
                fi

                echo -e "\033[1;34m$line\033[0m" >> "$temp_file"
                ((discovered++))
                log "info" "Detected hellocron job: already managed"
                continue
            fi

            if [[ "$verbose" == "true" ]]; then
                log "debug" "Found match: schedule='$schedule', command='$command'"
            fi

            generate_monitor_name "$command"
            local monitor_name="$MONITOR_NAME"

            local suggested_tags=""
            if [[ "$command" == *"backup"* ]]; then
                suggested_tags="backup"
            elif [[ "$command" == *"clean"* || "$command" == *"purge"* ]]; then
                suggested_tags="maintenance"
            elif [[ "$command" == *"update"* || "$command" == *"upgrade"* ]]; then
                suggested_tags="update"
            fi

            local entry=""
            if [[ -n "$suggested_tags" ]]; then
                if [[ -n "$default_project" ]]; then
                    entry=$(printf "$template --tags %s --project %s" "$schedule" "$script_absolute_path" "$monitor_name" "$suggested_tags" "$default_project" "$command")
                else
                    entry=$(printf "$template --tags %s" "$schedule" "$script_absolute_path" "$monitor_name" "$suggested_tags" "$command")
                fi
            else
                if [[ -n "$default_project" ]]; then
                    entry=$(printf "$template --project %s" "$schedule" "$script_absolute_path" "$monitor_name" "$default_project" "$command")
                else
                    entry=$(printf "$template" "$schedule" "$script_absolute_path" "$monitor_name" "$command")
                fi
            fi

            if check_cron_entry_exists "$entry"; then
                echo -e "\033[1;37m$entry\033[0m" >> "$temp_file"
                log "info" "Detected job: $monitor_name ($schedule) - already exists in crontab"
            else
                echo -e "\033[1;33m$entry\033[0m" >> "$temp_file"
                log "info" "Detected job: $monitor_name ($schedule) - to be added"
            fi
            ((discovered++))

        elif [[ "$line" =~ ^[[:space:]]*@(reboot|yearly|annually|monthly|weekly|daily|hourly)[[:space:]]+(.+) ]]; then
            local schedule="@${BASH_REMATCH[1]}"
            local command="${BASH_REMATCH[2]}"

            command=$(echo "$command" | sed 's/[[:space:]]*#.*$//')

            if [[ "$command" == *"hellocron.sh run"* || "$command" == *"hellocron.sh ping"* || "$command" == *"hellocron run"* || "$command" == *"hellocron ping"* ]]; then
                if [[ "$verbose" == "true" ]]; then
                    log "debug" "Found hellocron entry: $command"
                fi

                echo -e "\033[1;34m$line\033[0m" >> "$temp_file"
                ((discovered++))
                log "info" "Detected hellocron job: already managed"
                continue
            fi

            if [[ "$verbose" == "true" ]]; then
                log "debug" "Found special job: schedule='$schedule', command='$command'"
            fi

            generate_monitor_name "$command"
            local monitor_name="$MONITOR_NAME"

            local suggested_tags=""
            if [[ "$command" == *"backup"* ]]; then
                suggested_tags="backup"
            elif [[ "$command" == *"clean"* || "$command" == *"purge"* ]]; then
                suggested_tags="maintenance"
            elif [[ "$command" == *"update"* || "$command" == *"upgrade"* ]]; then
                suggested_tags="update"
            fi

            if [[ -n "$suggested_tags" ]]; then
                suggested_tags="${suggested_tags},${BASH_REMATCH[1]}"
            else
                suggested_tags="${BASH_REMATCH[1]}"
            fi

            local entry=""
            if [[ -n "$default_project" ]]; then
                entry=$(printf "$template --tags %s --project %s" "$schedule" "$script_absolute_path" "$monitor_name" "$suggested_tags" "$default_project" "$command")
            else
                entry=$(printf "$template --tags %s" "$schedule" "$script_absolute_path" "$monitor_name" "$suggested_tags" "$command")
            fi

            if check_cron_entry_exists "$entry"; then
                echo -e "\033[1;37m$entry\033[0m" >> "$temp_file"
                log "info" "Detected job: $monitor_name ($schedule) - already exists in crontab"
            else
                echo -e "\033[1;33m$entry\033[0m" >> "$temp_file"
                log "info" "Detected job: $monitor_name ($schedule) - to be added"
            fi
            ((discovered++))

        else
            if [[ "$verbose" == "true" ]]; then
                log "debug" "Unrecognized line format: $line"
            fi
        fi
    done <<< "$content"

    log "info" "Discovered $discovered cron jobs"

    if [[ "$discovered" -eq 0 ]]; then
        log "warn" "No cron jobs detected"
        rm -f "$temp_file"
        return 0
    fi

    if [[ -n "$output_file" ]]; then
        mv "$temp_file" "$output_file"
        log "info" "Monitoring config written to: $output_file"
    else
        echo -e "\n--- Monitoring configuration for discovered cron jobs ---\n"
        echo -e "\033[1;32mColor legend:\033[0m"
        echo -e "  \033[1;33m■ Orange\033[0m - job to be added to crontab"
        echo -e "  \033[1;34m■ Blue\033[0m   - job already managed by hellocron.sh"
        echo -e "  \033[1;37m■ Gray\033[0m   - job already exists in crontab (not hellocron)"
        echo ""
        cat "$temp_file"
        echo -e "\n--- End of configuration ---\n"
        echo "To use this configuration, add the orange lines to the appropriate script or crontab file."
        echo "Blue lines are jobs already managed by hellocron.sh."
        echo "Gray lines are jobs that already exist in crontab."
        rm -f "$temp_file"
    fi

    return 0
}

main() {
    check_dependencies

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                if [[ -n "$2" ]]; then
                    CONFIG_FILE="$2"
                    log "debug" "Using global config file: $CONFIG_FILE"
                    shift 2
                else
                    log "error" "Option --config requires a file path"
                    exit 1
                fi
                ;;
            -v|--verbose)
                VERBOSE=true
                log "debug" "Verbose mode enabled"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    load_config

    if [[ $# -eq 0 ]]; then
        cmd_help
        exit 0
    fi

    local command="$1"
    shift

    case "$command" in
        help)
            cmd_help
            ;;
        version)
            cmd_version
            ;;
        configure)
            cmd_configure "$@"
            ;;
        apply)
            cmd_apply "$@"
            ;;
        export)
            cmd_export "$@"
            ;;
        ping)
            cmd_ping "$@"
            ;;
        run)
            cmd_run "$@"
            ;;
        discover)
            cmd_discover "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        doctor)
            cmd_doctor "$@"
            ;;
        *)
            log "error" "Unknown command: $command"
            cmd_help
            exit 1
            ;;
    esac

    exit $?
}

main "$@"