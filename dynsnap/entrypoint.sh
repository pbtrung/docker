#!/bin/ash

# Exit on error
set -eu

# Configuration
readonly CONFIG_FILE="${MUSIC_CONFIG_FILE:-/music/config.json}"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FORMAT="[%Y-%m-%d %H:%M:%S]"

# Configuration variables (set from config file)
SNAPSERVER_CONFIG=""
SNAPFIFO=""
DB_URL=""
DB_FILE=""
OUTPUT_DIR=""

# Log with timestamp
log() {
    echo "[$(date +"$LOG_FORMAT")] [$SCRIPT_NAME] $*" >&2
}

# Log error and exit
die() {
    local msg="$1"
    local code="${2:-1}"
    log "ERROR: $msg"
    exit "$code"
}

# Load config
load_config() {
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    
    log "Loading configuration from $CONFIG_FILE"
    
    # Validate JSON syntax
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        die "Invalid JSON in config file: $CONFIG_FILE"
    fi
    
    # Load configuration with defaults
    SNAPSERVER_CONFIG=$(jq -r '.snapserver_config // empty' "$CONFIG_FILE")
    SNAPFIFO=$(jq -r '.snapfifo // empty' "$CONFIG_FILE")
    DB_URL=$(jq -r '.db_url // empty' "$CONFIG_FILE")
    DB_FILE=$(jq -r '.db_file // empty' "$CONFIG_FILE")
    OUTPUT_DIR=$(jq -r '.output_dir // "/music/downloads"' "$CONFIG_FILE")
    
    # Validate required fields
    required_fields="SNAPSERVER_CONFIG DB_URL DB_FILE"
    for field in $required_fields; do
        eval "value=\$$field"
        if [ -z "$value" ]; then
            field_lower=$(echo "$field" | tr 'A-Z' 'a-z')
            die "Required configuration field missing or empty: $field_lower"
        fi
    done
    
    log "Configuration loaded successfully"
}

# Start snapserver
start_snapserver() {
    if [ ! -f "$SNAPSERVER_CONFIG" ]; then
        log "WARNING: Skipping snapserver start (config not found)"
        return 0
    fi
    
    log "Starting snapserver with config: $SNAPSERVER_CONFIG"
    
    if snapserver --config "$SNAPSERVER_CONFIG" >/dev/null 2>&1 & then
        SNAPSERVER_PID=$!
        log "Snapserver started with PID: $SNAPSERVER_PID"
        
        sleep 2
        if ! kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
            log "WARNING: Snapserver appears to have exited immediately"
            SNAPSERVER_PID=""
            return 1
        fi
    else
        log "WARNING: Failed to start snapserver"
        return 1
    fi
}

# dynaudnorm --help