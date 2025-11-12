#!/bin/bash

# Exit on error
set -eu

log_message() {
    local msg="$1"
    echo "$msg"
    mosquitto_pub -h $MOSQUITTO_HOST -p $MOSQUITTO_PORT \
        -t "music/log" -m "$msg" 2>/dev/null || true
}

cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ icecast 2>/dev/null || true
    pkill -P $$ mosquitto 2>/dev/null || true
    exit 1
}

trap cleanup INT TERM EXIT

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    ICECAST_CONF=$(jq -r '.icecast_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    MOSQUITTO_CONF=$(jq -r '.mosquitto_conf' "$config_file")
    MOSQUITTO_HOST=$(jq -r '.mosquitto_host' "$config_file")
    MOSQUITTO_PORT=$(jq -r '.mosquitto_port' "$config_file")
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "ICECAST_CONF: $ICECAST_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
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

start_icecast() {
    log_message "Starting icecast with config: $ICECAST_CONF"
    
    if [ ! -f "$ICECAST_CONF" ]; then
        log_message "Error: Config file not found: $ICECAST_CONF"
        exit 1
    fi
    
    rsas -c "$ICECAST_CONF" 2>&1 &
    local icecast_pid=$!
    log_message "Icecast started with PID: $icecast_pid"
    
    sleep 2
    if ! kill -0 $icecast_pid 2>/dev/null; then
        log_message "Error: icecast failed to start or crashed immediately"
        exit 1
    fi
    
    log_message "Icecast is running successfully"
}

start_mosquitto() {
    log_message "Starting mosquitto with config: $MOSQUITTO_CONF"
    
    if [ ! -f "$MOSQUITTO_CONF" ]; then
        log_message "Error: Mosquitto config file not found: $MOSQUITTO_CONF"
        exit 1
    fi
    
    mosquitto -c "$MOSQUITTO_CONF" 2>&1 &
    local mosquitto_pid=$!
    log_message "Mosquitto started with PID: $mosquitto_pid"
    
    sleep 2
    if ! kill -0 $mosquitto_pid 2>/dev/null; then
        log_message "Error: mosquitto failed to start or crashed immediately"
        exit 1
    fi
    
    log_message "Mosquitto is running successfully"
}

get_random_track() {
    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
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
        -readrate 1.03 -readrate_initial_burst 10 -i "$fullname" \
        -c:a copy -f $audio_format \
        -content_type "$content_type" -ice_description "$opus_metadata" \
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
    log_message "Starting music playback loop..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    
    while true; do
        local path=$(get_random_track)
        local fname=${path##*/}
        local fullname="$DOWNLOADS_DIR/$fname"
        
        if ! download_track "$path"; then
            log_message "Download failed, skipping to next track..."
            sleep 1
            continue
        fi
        
        if ! play_track "$fullname"; then
            log_message "Skipping to next track..."
            sleep 1
            continue
        fi
        
        sleep 1
    done
}

main() {
    load_config
    start_mosquitto
    download_database
    start_icecast
    playback_loop
}

main
