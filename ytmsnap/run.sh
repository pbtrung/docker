#!/bin/ash

set -eu

readonly CONFIG_FILE="${MUSIC_CONFIG_FILE:-/music/config.json}"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FORMAT="[%Y-%m-%d %H:%M:%S]"

SNAPSERVER_PID=""
CONSECUTIVE_FAILURES=0

SNAPSERVER_CONFIG=""
SNAPFIFO=""
DB_URL=""
DB_FILE=""
COOKIES_FILE=""
OUTPUT_DIR=""
MAX_RETRIES=""
SLEEP_INTERVAL=""
MAX_CONSECUTIVE_FAILURES=""

log() {
    echo "[$(date +"$LOG_FORMAT")] [$SCRIPT_NAME] $*" >&2
}

die() {
    local msg="$1"
    local code="${2:-1}"
    log "ERROR: $msg"
    exit "$code"
}

cleanup() {
    log "Cleaning up..."
    
    if [ -n "$SNAPSERVER_PID" ]; then
        if kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
            log "Stopping snapserver (PID: $SNAPSERVER_PID)"
            kill -TERM "$SNAPSERVER_PID" 2>/dev/null || true
            
            count=0
            while kill -0 "$SNAPSERVER_PID" 2>/dev/null && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            if kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
                log "Force killing snapserver"
                kill -KILL "$SNAPSERVER_PID" 2>/dev/null || true
            fi
        fi
    fi
    
    if [ -n "${OUTPUT_DIR:-}" ]; then
        find "$OUTPUT_DIR" -type f -delete 2>/dev/null || true
    fi
}

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

load_config() {
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    
    log "Loading configuration from $CONFIG_FILE"
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        die "Invalid JSON in config file: $CONFIG_FILE"
    fi
    
    SNAPSERVER_CONFIG=$(jq -r '.snapserver_config // empty' "$CONFIG_FILE")
    SNAPFIFO=$(jq -r '.snapfifo // empty' "$CONFIG_FILE")
    DB_URL=$(jq -r '.db_url // empty' "$CONFIG_FILE")
    DB_FILE=$(jq -r '.db_file // empty' "$CONFIG_FILE")
    COOKIES_FILE=$(jq -r '.cookies_file // empty' "$CONFIG_FILE")
    OUTPUT_DIR=$(jq -r '.output_dir // "/music/downloads"' "$CONFIG_FILE")
    MAX_RETRIES=$(jq -r '.max_retries // 3' "$CONFIG_FILE")
    SLEEP_INTERVAL=$(jq -r '.sleep_interval // 1' "$CONFIG_FILE")
    MAX_CONSECUTIVE_FAILURES=$(jq -r '.max_consecutive_failures // 5' "$CONFIG_FILE")
    
    required_fields="SNAPSERVER_CONFIG DB_URL DB_FILE COOKIES_FILE"
    for field in $required_fields; do
        eval "value=\$$field"
        if [ -z "$value" ]; then
            field_lower=$(echo "$field" | tr 'A-Z' 'a-z')
            die "Required configuration field missing or empty: $field_lower"
        fi
    done
    
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

setup_environment() {
    mkdir -p "$OUTPUT_DIR" || die "Failed to create output directory: $OUTPUT_DIR"
    
    if [ ! -f "$SNAPSERVER_CONFIG" ]; then
        log "WARNING: Snapserver config not found: $SNAPSERVER_CONFIG"
    fi
    
    [ -f "$COOKIES_FILE" ] || die "Cookies file not found: $COOKIES_FILE"
    
    if [ -n "$SNAPFIFO" ] && [ ! -p "$SNAPFIFO" ]; then
        log "WARNING: FIFO does not exist: $SNAPFIFO"
    fi
    
    log "Environment setup complete"
}

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

download_database() {
    log "Downloading database from: $DB_URL"
    
    retry_count=0
    temp_db="${DB_FILE}.tmp"
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if wget "$DB_URL" -O "$temp_db" -q --timeout=30 --tries=1; then
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

get_random_upload() {
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM uploads;" 2>/dev/null) || {
        log "Failed to query database"
        return 1
    }
    
    if [ "$count" -eq 0 ]; then
        log "No uploads found in database"
        return 1
    else
        log "Number of uploads: $count"
    fi
    
    random_id=$(shuf -i 1-"$count" -n 1)
    
    upload_json=$(sqlite3 "$DB_FILE" "SELECT upload FROM uploads WHERE upload_id = $random_id;" 2>/dev/null)
    
    if [ -z "$upload_json" ]; then
        log "Upload with ID $random_id not found"
        return 1
    else
        log "Got upload_id: $random_id"
    fi
    
    echo "$upload_json"
}

process_video() {
    local video_id="$1"
    local title="$2"
    local url="https://music.youtube.com/watch?v=$video_id"
    
    log "Processing Video ID: $video_id"
    
    rand_name=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 25 | head -n 1)
    temp_file="${OUTPUT_DIR}/${rand_name}"
    
    if ! yt-dlp --cookies "$COOKIES_FILE" --no-playlist --output "${temp_file}.%(ext)s" "$url" 2>&1; then
        log "Failed to download: $video_id"
        return 1
    fi
    
    actual_file=$(find "$OUTPUT_DIR" -iname "${rand_name}*" -type f | head -n 1)
    
    if [ ! -f "$actual_file" ]; then
        log "Downloaded file not found for: $video_id"
        return 1
    fi
    
    log "Successfully downloaded: $video_id"
    
    if [ -n "$SNAPFIFO" ] && [ -p "$SNAPFIFO" ]; then
        stream_audio "$actual_file" "$SNAPFIFO" "$title"
    fi
    
    rm -f "$actual_file"
    
    return 0
}

show_ffmpeg_progress() {
    local title="$1"
    stdbuf -oL awk -v title="$title" '
        /Duration:/ {
            dur = $2
            sub(/,/, "", dur)
            split(dur, parts, ":")
            dur_secs = parts[1]*3600 + parts[2]*60 + parts[3]
        }
        /time=/ {
            match($0, /time=([0-9:.]+)/, time_match)
            if (time_match[1]) {
                split(time_match[1], parts, ":")
                curr_secs = parts[1]*3600 + parts[2]*60 + parts[3]
                curr_secs_int = int(curr_secs)
                
                if (curr_secs_int > last_secs) {
                    last_secs = curr_secs_int
                    pct = (dur_secs > 0) ? (curr_secs / dur_secs * 100) : 0
                    printf "\r%s\n\r[%s/%s] %.1f%%", title, time_match[1], dur, pct
                    fflush()
                }
            }
        }
        END {
            printf "\n"
        }
    '
}

stream_audio() {
    local input_file="$1"
    local fifo_path="$2"
    local title="$3"
    local infopipe="/tmp/infopipe.$$"
    local gwsocket_pid=""
    
    log "Streaming: $(basename "$input_file")"
    
    rm -f "$infopipe"
    mkfifo "$infopipe" || {
        log "WARNING: Failed to create info pipe"
        return 1
    }
    
    (gwsocket --port=9000 --addr=0.0.0.0 --std < "$infopipe") &
    gwsocket_pid=$!
    
    sleep 0.5
    
    (ffmpeg -hide_banner -y -i "$input_file" \
        -af "dynaudnorm=f=500:g=31:p=0.925:m=8:r=0.25:s=25.0" \
        -f s16le -acodec pcm_s16le -ac 2 -ar 44100 \
        "$fifo_path" 2>&1 | show_ffmpeg_progress "$title" > "$infopipe") &
    
    local ffmpeg_pid=$!
    
    wait "$ffmpeg_pid"
    local exit_code=$?
    
    exec 3>"$infopipe"
    echo "" >&3
    exec 3>&-
    
    sleep 0.5
    
    if [ -n "$gwsocket_pid" ] && kill -0 "$gwsocket_pid" 2>/dev/null; then
        kill -TERM "$gwsocket_pid" 2>/dev/null || true
        wait "$gwsocket_pid" 2>/dev/null || true
    fi
    
    rm -f "$infopipe"
    
    if [ $exit_code -ne 0 ]; then
        log "WARNING: Failed to stream audio (exit code: $exit_code)"
        return 1
    fi
    
    log "Stream completed successfully"
    return 0
}

main_loop() {
    log "Starting main processing loop"
    
    while true; do
        upload_json=""
        video_id=""
        title=""
        
        if ! upload_json=$(get_random_upload); then
            sleep 5
            continue
        fi
        
        video_id=$(echo "$upload_json" | jq -r '.videoId // empty' 2>/dev/null)
        if [ -z "$video_id" ]; then
            log "No videoId found in upload"
            sleep 5
            continue
        fi

        title=$(echo "$upload_json" | jq -r '.title // empty' 2>/dev/null)
        
        if process_video "$video_id" "$title"; then
            CONSECUTIVE_FAILURES=0
        else
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            
            if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
                log "Too many consecutive download failures ($CONSECUTIVE_FAILURES)"
                sleep 5
                continue
            fi
        fi
        
        sleep "$SLEEP_INTERVAL"
    done
}

main() {
    log "Starting $SCRIPT_NAME"
    
    trap cleanup INT TERM EXIT
    
    check_dependencies
    load_config
    setup_environment
    
    start_snapserver
    download_database
    
    main_loop
}

if [ "$0" = "${0%/*}/$(basename "$0")" ]; then
    main "$@"
fi