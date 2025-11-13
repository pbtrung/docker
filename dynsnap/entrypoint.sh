#!/bin/ash

# Exit on error
set -eu
set -o pipefail

# Global PID tracking
SNAPSERVER_PID=""
MOSQUITTO_PID=""

# Failure tracking
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

log_message() {
    local msg="$1"
    echo "$msg"
    mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT \
        -t "music/log" -m "$msg" 2>/dev/null || true
}

cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    
    if [ -n "$SNAPSERVER_PID" ] && kill -0 $SNAPSERVER_PID 2>/dev/null; then
        kill $SNAPSERVER_PID 2>/dev/null || true
    fi
    
    if [ -n "$MOSQUITTO_PID" ] && kill -0 $MOSQUITTO_PID 2>/dev/null; then
        kill $MOSQUITTO_PID 2>/dev/null || true
    fi

    rm -f "$SNAPFIFO" 2>/dev/null || true
    
    exit 1
}

trap cleanup INT TERM

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    SNAPSERVER_CONF=$(jq -r '.snapserver_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    SNAPFIFO=$(jq -r '.snapfifo' "$config_file")
    MOSQUITTO_CONF=$(jq -r '.mosquitto_conf' "$config_file")
    MOSQUITTO_HOST=$(jq -r '.mosquitto_host' "$config_file")
    MOSQUITTO_PORT=$(jq -r '.mosquitto_port' "$config_file")
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "SNAPSERVER_CONF: $SNAPSERVER_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "DB_PATH: $DB_PATH"
    log_message "SNAPFIFO: $SNAPFIFO"
    log_message "MOSQUITTO_CONF: $MOSQUITTO_CONF"
    log_message "MOSQUITTO_HOST: $MOSQUITTO_HOST"
    log_message "MOSQUITTO_PORT: $MOSQUITTO_PORT"
    log_message "===================="
}

download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>&1; then
        log_message "Error: Failed to download database from $DB_URL"
        exit 1
    fi
}

start_snapserver() {
    log_message "Starting snapserver with config: $SNAPSERVER_CONF"
    
    if [ ! -f "$SNAPSERVER_CONF" ]; then
        log_message "Error: Config file not found: $SNAPSERVER_CONF"
        exit 1
    fi
    
    snapserver --config "$SNAPSERVER_CONF" &
    SNAPSERVER_PID=$!
    log_message "Snapserver started with PID: $SNAPSERVER_PID"
    
    # Wait for snapserver to start with retries
    local retries=5
    while [ $retries -gt 0 ]; do
        sleep 1
        if kill -0 $SNAPSERVER_PID 2>/dev/null; then
            log_message "Snapserver is running successfully"
            return 0
        fi
        retries=$((retries - 1))
    done
    
    log_message "Error: snapserver failed to start"
    exit 1
}

start_mosquitto() {
    log_message "Starting mosquitto with config: $MOSQUITTO_CONF"
    
    if [ ! -f "$MOSQUITTO_CONF" ]; then
        log_message "Error: Mosquitto config file not found: $MOSQUITTO_CONF"
        exit 1
    fi
    
    mosquitto -c "$MOSQUITTO_CONF" 2>&1 &
    MOSQUITTO_PID=$!
    log_message "Mosquitto started with PID: $MOSQUITTO_PID"
    
    # Wait for mosquitto to start with retries
    local retries=5
    while [ $retries -gt 0 ]; do
        sleep 1
        if kill -0 $MOSQUITTO_PID 2>/dev/null; then
            log_message "Mosquitto is running successfully"
            return 0
        fi
        retries=$((retries - 1))
    done
    
    log_message "Error: mosquitto failed to start"
    exit 1
}

check_services_health() {
    local all_healthy=true
    
    if [ -n "$SNAPSERVER_PID" ]; then
        if ! kill -0 $SNAPSERVER_PID 2>/dev/null; then
            log_message "WARNING: Snapserver (PID $SNAPSERVER_PID) is not running!"
            all_healthy=false
        fi
    fi
    
    if [ -n "$MOSQUITTO_PID" ]; then
        if ! kill -0 $MOSQUITTO_PID 2>/dev/null; then
            log_message "WARNING: Mosquitto (PID $MOSQUITTO_PID) is not running!"
            all_healthy=false
        fi
    fi
    
    if [ "$all_healthy" = false ]; then
        log_message "ERROR: Critical services have crashed. Exiting..."
        exit 1
    fi
}

get_random_track() {
    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    
    if [ -z "$total" ] || [ "$total" -eq 0 ]; then
        log_message "Error: Database is empty or invalid"
        return 1
    fi
    
    local random_id=$(shuf -i 1-"$total" -n 1)
    sqlite3 "$DB_PATH" "SELECT path FROM files WHERE id = $random_id;"
}

download_track() {
    local path="$1"
    
    log_message "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" \
        "$DOWNLOADS_DIR/" -v --stats 5s 2>&1; then
        log_message "Error: rclone failed to download $path"
        return 1
    fi
    return 0
}

mqtt_message() {
    local msg="$1"
    local topic="$2"
    mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT \
        -t "$topic" -m "$msg" -r 2>/dev/null || true
}

play_track() {
    local fullname="$1"

    if [ ! -f "$fullname" ]; then
        log_message "Error: File not found: $fullname"
        return 1
    fi

    log_message "Streaming: $fullname"

    opus_metadata=$(opusinfo "$fullname" 2>&1)
    mqtt_message "$opus_metadata" "music/info"

    ffmpeg -nostdin -hide_banner -progress pipe:1 \
        -stats_period 2 -y -i "$fullname" \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -f s16le -ar 48000 -ac 2 "$SNAPFIFO" 2>&1 | \
        mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT -t "music/log" -l &
    local pipeline_pid=$!
    
    wait $pipeline_pid
    local ffmpeg_status=$?
    
    if [ $ffmpeg_status -ne 0 ]; then
        log_message "Error: Streaming failed (exit code: $ffmpeg_status)"
        rm -f "$fullname"
        return 1
    fi
    
    rm -f "$fullname"
    log_message "Finished streaming: $fullname"
    return 0
}

playback_loop() {
    log_message "Starting music playback loop..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    
    while true; do
        # Health check for background services
        check_services_health
        
        # Check if we've hit max consecutive failures
        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            log_message "ERROR: Reached maximum consecutive failures ($MAX_CONSECUTIVE_FAILURES). Exiting..."
            exit 1
        fi
        
        local path=$(get_random_track)
        if [ -z "$path" ]; then
            log_message "Failed to get random track, retrying..."
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            sleep 2
            continue
        fi
        
        local fname=${path##*/}
        local fullname="$DOWNLOADS_DIR/$fname"
        
        if ! download_track "$path"; then
            log_message "Download failed, skipping to next track..."
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            sleep 2
            continue
        fi
        
        if ! play_track "$fullname"; then
            log_message "Playback failed, skipping to next track..."
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            sleep 2
            continue
        fi
        
        # Reset failure counter on success
        CONSECUTIVE_FAILURES=0
        sleep 1
    done
}

main() {
    load_config
    start_mosquitto
    download_database
    start_snapserver
    playback_loop
}

main
