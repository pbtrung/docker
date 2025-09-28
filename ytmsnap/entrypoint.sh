#!/bin/ash

# Music streaming script with YouTube Music integration
# Improved version with better error handling, logging, and maintainability

set -eu  # Exit on error, undefined vars (ash doesn't support pipefail)

# Configuration
readonly CONFIG_FILE="${MUSIC_CONFIG_FILE:-/music/config.json}"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FORMAT="[%Y-%m-%d %H:%M:%S]"

# Global variables
SNAPSERVER_PID=""
CONSECUTIVE_FAILURES=0

# Configuration variables (set from config file)
SNAPSERVER_CONFIG=""
SNAPFIFO=""
DB_URL=""
DB_FILE=""
COOKIES_FILE=""
OUTPUT_DIR=""
MAX_RETRIES=""
SLEEP_INTERVAL=""
MAX_CONSECUTIVE_FAILURES=""

#######################################
# Log message with timestamp
# Arguments:
#   Message to log
#######################################
log() {
    echo "[$(date +"$LOG_FORMAT")] [$SCRIPT_NAME] $*" >&2
}

#######################################
# Log error and exit
# Arguments:
#   Error message
#   Exit code (optional, default: 1)
#######################################
die() {
    local msg="$1"
    local code="${2:-1}"
    log "ERROR: $msg"
    exit "$code"
}

#######################################
# Cleanup resources on exit
#######################################
cleanup() {
    log "Cleaning up..."
    
    if [ -n "$SNAPSERVER_PID" ]; then
        if kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
            log "Stopping snapserver (PID: $SNAPSERVER_PID)"
            kill -TERM "$SNAPSERVER_PID" 2>/dev/null || true
            
            # Wait up to 10 seconds for graceful shutdown
            count=0
            while kill -0 "$SNAPSERVER_PID" 2>/dev/null && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            # Force kill if still running
            if kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
                log "Force killing snapserver"
                kill -KILL "$SNAPSERVER_PID" 2>/dev/null || true
            fi
        fi
    fi
    
    # Clean up any temporary files
    if [ -n "${OUTPUT_DIR:-}" ]; then
        find "$OUTPUT_DIR" -name "tmp_*" -type f -delete 2>/dev/null || true
    fi
}

#######################################
# Validate required commands exist
#######################################
check_dependencies() {
    missing_deps=""
    required_commands="jq yt-dlp sqlite3 shuf ffmpeg snapserver wget"
    
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps="$missing_deps $cmd"
        fi
    done
    
    if [ -n "$missing_deps" ]; then
        die "Missing required dependencies:$missing_deps"
    fi
    
    log "All dependencies found"
}

#######################################
# Load and validate configuration
#######################################
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
    COOKIES_FILE=$(jq -r '.cookies_file // empty' "$CONFIG_FILE")
    OUTPUT_DIR=$(jq -r '.output_dir // "/music/downloads"' "$CONFIG_FILE")
    MAX_RETRIES=$(jq -r '.max_retries // 3' "$CONFIG_FILE")
    SLEEP_INTERVAL=$(jq -r '.sleep_interval // 1' "$CONFIG_FILE")
    MAX_CONSECUTIVE_FAILURES=$(jq -r '.max_consecutive_failures // 5' "$CONFIG_FILE")
    
    # Validate required fields
    required_fields="SNAPSERVER_CONFIG DB_URL DB_FILE COOKIES_FILE"
    for field in $required_fields; do
        eval "value=\$$field"
        if [ -z "$value" ]; then
            field_lower=$(echo "$field" | tr 'A-Z' 'a-z')
            die "Required configuration field missing or empty: $field_lower"
        fi
    done
    
    # Validate numeric fields
    if ! echo "$MAX_RETRIES" | grep -q '^[0-9]*$' || [ "$MAX_RETRIES" -lt 1 ]; then
        die "max_retries must be a positive integer"
    fi
    
    if ! echo "$SLEEP_INTERVAL" | grep -q '^[0-9]*$' || [ "$SLEEP_INTERVAL" -lt 1 ]; then
        die "sleep_interval must be a positive integer"
    fi
    
    if ! echo "$MAX_CONSECUTIVE_FAILURES" | grep -q '^[0-9]*$' || [ "$MAX_CONSECUTIVE_FAILURES" -lt 1 ]; then
        die "max_consecutive_failures must be a positive integer"
    fi
    
    log "Configuration loaded successfully"
}

#######################################
# Setup directories and files
#######################################
setup_environment() {
    # Create output directory
    mkdir -p "$OUTPUT_DIR" || die "Failed to create output directory: $OUTPUT_DIR"
    
    # Check snapserver config
    if [ ! -f "$SNAPSERVER_CONFIG" ]; then
        log "WARNING: Snapserver config not found: $SNAPSERVER_CONFIG"
    fi
    
    # Check cookies file
    [ -f "$COOKIES_FILE" ] || die "Cookies file not found: $COOKIES_FILE"
    
    # Check if FIFO exists or can be created
    if [ -n "$SNAPFIFO" ] && [ ! -p "$SNAPFIFO" ]; then
        log "WARNING: FIFO does not exist: $SNAPFIFO"
    fi
    
    log "Environment setup complete"
}

#######################################
# Start snapserver process
#######################################
start_snapserver() {
    if [ ! -f "$SNAPSERVER_CONFIG" ]; then
        log "WARNING: Skipping snapserver start (config not found)"
        return 0
    fi
    
    log "Starting snapserver with config: $SNAPSERVER_CONFIG"
    
    if snapserver --config "$SNAPSERVER_CONFIG" >/dev/null 2>&1 & then
        SNAPSERVER_PID=$!
        log "Snapserver started with PID: $SNAPSERVER_PID"
        
        # Wait a moment and verify it's still running
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

#######################################
# Download database with retry logic
#######################################
download_database() {
    log "Downloading database from: $DB_URL"
    
    retry_count=0
    temp_db="${DB_FILE}.tmp"
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if wget "$DB_URL" -O "$temp_db" -q --timeout=30 --tries=1; then
            # Verify the downloaded file is a valid SQLite database
            if sqlite3 "$temp_db" "SELECT COUNT(*) FROM uploads;" >/dev/null 2>&1; then
                mv "$temp_db" "$DB_FILE" || die "Failed to move database file"
                log "Database downloaded and verified successfully"
                return 0
            else
                log "Downloaded file is not a valid database"
                rm -f "$temp_db"
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $MAX_RETRIES ]; then
            log "Download attempt $retry_count failed. Retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    die "Failed to download database after $MAX_RETRIES attempts"
}

#######################################
# Get random upload from database
# Outputs: JSON string of upload data
#######################################
get_random_upload() {
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM uploads;" 2>/dev/null) || {
        log "Failed to query database"
        return 1
    }
    
    if [ "$count" -eq 0 ]; then
        log "No uploads found in database"
        return 1
    fi
    
    random_id=$(shuf -i 1-"$count" -n 1)
    
    upload_json=$(sqlite3 "$DB_FILE" "SELECT upload FROM uploads WHERE upload_id = $random_id;" 2>/dev/null)
    
    if [ -z "$upload_json" ]; then
        log "Upload with ID $random_id not found"
        return 1
    fi
    
    echo "$upload_json"
}

#######################################
# Download and process audio
# Arguments:
#   video_id - YouTube video ID
#   upload_id - Database upload ID
# Returns:
#   0 on success, 1 on failure
#######################################
process_video() {
    video_id="$1"
    url="https://music.youtube.com/watch?v=$video_id"
    
    log "Processing Video ID: $video_id"
    
    # Generate random filename
    rand_name=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    temp_file="${OUTPUT_DIR}/${rand_name}"
    
    # Download with yt-dlp - ash doesn't support arrays, use string
    if ! yt-dlp --cookies "$COOKIES_FILE" --no-playlist --output "${temp_file}.%(ext)s" "$url" 2>&1; then
        log "Failed to download: $video_id"
        return 1
    fi
    
    # Find the actual downloaded file (yt-dlp adds extension)
    actual_file=$(find "$OUTPUT_DIR" -name "${rand_name}*" -type f | head -n 1)
    
    if [ ! -f "$actual_file" ]; then
        log "Downloaded file not found for: $video_id"
        return 1
    fi
    
    log "Successfully downloaded: $video_id"
    
    # Apply loudness normalization and stream to FIFO
    if [ -n "$SNAPFIFO" ] && [ -p "$SNAPFIFO" ]; then
        stream_audio "$actual_file" "$SNAPFIFO"
    fi
    
    # Clean up temporary file
    rm -f "$actual_file"
    
    return 0
}

#######################################
# Apply loudness normalization and stream to FIFO
# Arguments:
#   input_file - Path to audio file
#   fifo_path - Path to FIFO
#######################################
stream_audio() {
    input_file="$1"
    fifo_path="$2"
    
    log "Streaming audio with loudnorm"
    
    if ! ffmpeg -y -i "$input_file" \
        -f s16le -acodec pcm_s16le -ac 2 -ar 44100 "$fifo_path" 2>/dev/null; then
        log "WARNING: Failed to convert audio file: $(basename "$input_file")"
        return 1
    fi
    
    log "Successfully streamed normalized audio to FIFO"
    return 0
}

#######################################
# Main processing loop
#######################################
main_loop() {
    log "Starting main processing loop"
    
    while true; do
        upload_json=""
        video_id=""
        upload_id=""
        
        # Get random upload
        if ! upload_json=$(get_random_upload); then
            sleep 30
            continue
        fi
        
        # Extract video ID
        video_id=$(echo "$upload_json" | jq -r '.videoId // empty' 2>/dev/null)
        if [ -z "$video_id" ]; then
            log "No videoId found in upload"
            sleep 5
            continue
        fi
        
        # Process the video
        if process_video "$video_id"; then
            CONSECUTIVE_FAILURES=0
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            
            if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                die "Too many consecutive download failures ($CONSECUTIVE_FAILURES)"
            fi
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
}

#######################################
# Main function
#######################################
main() {
    log "Starting $SCRIPT_NAME"
    
    # Set up signal handling
    trap cleanup INT TERM EXIT
    
    # Initialize
    check_dependencies
    load_config
    setup_environment
    
    # Start services
    start_snapserver
    download_database
    
    # Run main loop
    main_loop
}

# Run main function if script is executed directly
if [ "$0" = "${0%/*}/$(basename "$0")" ]; then
    main "$@"
fi