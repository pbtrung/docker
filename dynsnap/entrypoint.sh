#!/bin/bash

# Exit on error
set -eu

# Global PID tracking
RSAS_PID=""
MOSQUITTO_PID=""

# Failure tracking
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5

# Queue management
QUEUE_DIR=""
CURRENT_TRACK=""
NEXT_TRACK=""
DOWNLOAD_PID=""

log_message() {
    local msg="$1"
    echo "$msg"
    mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT \
        -t "music/log" -m "$msg" 2>/dev/null || true
}

cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    
    if [ -n "$DOWNLOAD_PID" ] && kill -0 $DOWNLOAD_PID 2>/dev/null; then
        kill $DOWNLOAD_PID 2>/dev/null || true
    fi
    
    if [ -n "$RSAS_PID" ] && kill -0 $RSAS_PID 2>/dev/null; then
        kill $RSAS_PID 2>/dev/null || true
    fi
    
    if [ -n "$MOSQUITTO_PID" ] && kill -0 $MOSQUITTO_PID 2>/dev/null; then
        kill $MOSQUITTO_PID 2>/dev/null || true
    fi
    
    exit 1
}

trap cleanup INT TERM

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    RSAS_CONF=$(jq -r '.rsas_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    MOSQUITTO_CONF=$(jq -r '.mosquitto_conf' "$config_file")
    MOSQUITTO_HOST=$(jq -r '.mosquitto_host' "$config_file")
    MOSQUITTO_PORT=$(jq -r '.mosquitto_port' "$config_file")
    
    # Set up queue directory
    QUEUE_DIR="$DOWNLOADS_DIR/queue"
    mkdir -p "$QUEUE_DIR"
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "RSAS_CONF: $RSAS_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "QUEUE_DIR: $QUEUE_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "DB_PATH: $DB_PATH"
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

start_rsas() {
    log_message "Starting RSAS with config: $RSAS_CONF"
    
    if [ ! -f "$RSAS_CONF" ]; then
        log_message "Error: Config file not found: $RSAS_CONF"
        exit 1
    fi
    
    rsas -c "$RSAS_CONF" 2>&1 &
    RSAS_PID=$!
    log_message "RSAS started with PID: $RSAS_PID"
    
    # Wait for RSAS to start with retries
    local retries=5
    while [ $retries -gt 0 ]; do
        sleep 1
        if kill -0 $RSAS_PID 2>/dev/null; then
            log_message "RSAS is running successfully"
            return 0
        fi
        retries=$((retries - 1))
    done
    
    log_message "Error: RSAS failed to start"
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
    
    if [ -n "$RSAS_PID" ]; then
        if ! kill -0 $RSAS_PID 2>/dev/null; then
            log_message "WARNING: RSAS (PID $RSAS_PID) is not running!"
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
    local dest_file="$2"
    
    log_message "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" \
        "$QUEUE_DIR/" -v --stats 5s 2>&1; then
        log_message "Error: rclone failed to download $path"
        return 1
    fi
    
    # Move to destination with specific name
    local fname=${path##*/}
    mv "$QUEUE_DIR/$fname" "$dest_file" 2>/dev/null || true
    return 0
}

download_track_async() {
    local path="$1"
    local dest_file="$2"
    
    (
        download_track "$path" "$dest_file"
    ) &
    DOWNLOAD_PID=$!
}

wait_for_download() {
    if [ -n "$DOWNLOAD_PID" ] && kill -0 $DOWNLOAD_PID 2>/dev/null; then
        log_message "Waiting for download to complete (PID: $DOWNLOAD_PID)..."
        wait $DOWNLOAD_PID
        local status=$?
        DOWNLOAD_PID=""
        return $status
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

    local audio_format
    audio_format=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$fullname" 2>/dev/null)
    
    if [ -z "$audio_format" ]; then
        log_message "Error: Could not determine audio format"
        rm -f "$fullname"
        return 1
    fi
    
    log_message "Detected format: $audio_format"

    opus_metadata=$(opusinfo "$fullname" 2>&1)
    mqtt_message "$opus_metadata" "music/info"
    
    local content_type
    case "$audio_format" in
        opus)
            content_type="application/ogg"
            ;;
        mp3)
            content_type="audio/mpeg"
            ;;
        *)
            log_message "Warning: Unsupported format $audio_format, defaulting to audio/mpeg"
            content_type="audio/mpeg"
            ;;
    esac
    
    set -o pipefail

    ffmpeg -nostdin -hide_banner -progress pipe:1 -stats_period 2 \
        -readrate 1.02 -readrate_initial_burst 60 -i "$fullname" \
        -c:a copy -f $audio_format -content_type "$content_type" \
        "icecast://source:hackme@localhost:8000/stream" 2>&1 | \
        mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT -t "music/log" -l &
    local pipeline_pid=$!
    
    wait $pipeline_pid
    local ffmpeg_status=$?
    
    if [ $ffmpeg_status -ne 0 ]; then
        log_message "Error: Streaming to Icecast failed (exit code: $ffmpeg_status)"
        rm -f "$fullname"
        return 1
    fi
    
    rm -f "$fullname"
    log_message "Finished streaming: $fullname"
    return 0
}

playback_loop() {
    log_message "Starting music playback loop with queue system..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    find "$QUEUE_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    
    # Download first track to initialize
    log_message "Initializing queue with first track..."
    
    local path=$(get_random_track)
    if [ -z "$path" ]; then
        log_message "Failed to get first track"
        exit 1
    fi
    
    CURRENT_TRACK="$QUEUE_DIR/current.audio"
    if ! download_track "$path" "$CURRENT_TRACK"; then
        log_message "Failed to download first track"
        exit 1
    fi
    
    NEXT_TRACK="$QUEUE_DIR/next.audio"
    log_message "Queue initialized"
    
    while true; do
        # Health check for background services
        check_services_health
        
        # Check if we've hit max consecutive failures
        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
            log_message "ERROR: Reached maximum consecutive failures ($MAX_CONSECUTIVE_FAILURES). Exiting..."
            exit 1
        fi
        
        # Start downloading next track in background
        local next_path=$(get_random_track)
        if [ -z "$next_path" ]; then
            log_message "Failed to get next track for queue"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            sleep 2
            continue
        fi
        
        download_track_async "$next_path" "$NEXT_TRACK"
        
        # Play current track (this blocks until track finishes)
        if ! play_track "$CURRENT_TRACK"; then
            log_message "Playback failed, skipping to next track..."
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            
            # Wait for download to complete before continuing
            wait_for_download
            
            # Move next to current if it exists
            if [ -f "$NEXT_TRACK" ]; then
                mv "$NEXT_TRACK" "$CURRENT_TRACK"
            else
                # If next doesn't exist, download synchronously
                next_path=$(get_random_track)
                if [ -n "$next_path" ]; then
                    download_track "$next_path" "$CURRENT_TRACK" || true
                fi
            fi
            
            sleep 2
            continue
        fi
        
        # Reset failure counter on success
        CONSECUTIVE_FAILURES=0
        
        # Wait for background download to complete
        if ! wait_for_download; then
            log_message "Background download failed, fetching new track synchronously..."
            next_path=$(get_random_track)
            if [ -n "$next_path" ]; then
                download_track "$next_path" "$NEXT_TRACK" || true
            fi
        fi
        
        # Move next track to current for the next iteration
        if [ -f "$NEXT_TRACK" ]; then
            mv "$NEXT_TRACK" "$CURRENT_TRACK"
        else
            log_message "Warning: Next track not available, downloading now..."
            next_path=$(get_random_track)
            if [ -n "$next_path" ]; then
                download_track "$next_path" "$CURRENT_TRACK" || true
            fi
        fi
        
        sleep 1
    done
}

main() {
    load_config
    start_mosquitto
    download_database
    start_rsas
    playback_loop
}

main
