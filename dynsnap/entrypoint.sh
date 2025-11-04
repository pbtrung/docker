#!/bin/ash

# Exit on error
set -eu

log_message() {
    echo "$1"
    if [ -n "$INFOFIFO" ] && [ -p "$INFOFIFO" ]; then
        echo "$1" > "$INFOFIFO" 2>/dev/null || true
    fi
}

cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ snapserver 2>/dev/null || true
    pkill -P $$ gwsocket 2>/dev/null || true
    rm -f "$INFOFIFO" 2>/dev/null || true
    exit 1
}

trap cleanup INT TERM EXIT

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    SNAPSERVER_CONF=$(jq -r '.snapserver_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    SNAPFIFO=$(jq -r '.snapfifo' "$config_file")
    INFOFIFO=$(jq -r '.infofifo' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "SNAPSERVER_CONF: $SNAPSERVER_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "SNAPFIFO: $SNAPFIFO"
    log_message "DB_PATH: $DB_PATH"
    log_message "INFOFIFO: $INFOFIFO"
    log_message "===================="
}

download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>&1 | tee "$INFOFIFO"; then
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
    local snapserver_pid=$!
    log_message "Snapserver started with PID: $snapserver_pid"
    
    sleep 1
    if ! kill -0 $snapserver_pid 2>/dev/null; then
        log_message "Error: snapserver failed to start or crashed immediately"
        log_message "Try running manually: snapserver --config $SNAPSERVER_CONF"
        exit 1
    fi
    
    log_message "Snapserver is running successfully"
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
        "$DOWNLOADS_DIR/" -v --stats 5s 2>&1 | tee "$INFOFIFO"; then
        log_message "Error: rclone failed to download $path"
        return 1
    fi
    return 0
}

play_track() {
    local fullname="$1"

    if [ ! -f "$fullname" ]; then
        log_message "Error: File not found: $fullname"
        return 1
    fi

    log_message "Streaming: $fullname"

    if ! ffmpeg -nostdin -hide_banner -i "$fullname" \
        -map 0:a:0 \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -ar 48000 -sample_fmt s16 -ac 2 \
        "$SNAPFIFO" 2>"$INFOFIFO"; then
        log_message "Error: ffmpeg streaming failed"
        rm -f "$fullname"
        return 1
    fi
    
    rm -f "$fullname"
    log_message "Finished streaming: $fullname"
    return 0
}

start_gwsocket() {
    log_message "Creating FIFO and starting gwsocket..."
    rm -f "$INFOFIFO"
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO" &
    local gwsocket_pid=$!
    log_message "gwsocket started with PID: $gwsocket_pid"
    
    sleep 1
    if ! kill -0 $gwsocket_pid 2>/dev/null; then
        log_message "Error: gwsocket failed to start"
        exit 1
    fi
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
    start_gwsocket
    download_database
    start_snapserver
    playback_loop
}

main
