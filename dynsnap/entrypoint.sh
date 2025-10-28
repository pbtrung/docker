#!/bin/ash

set -eu

ICECAST_PID=""
GWSOCKET_PID=""
FFMPEG_PID=""

log_message() {
    echo "$1" | tee "$INFOFIFO" 2>/dev/null || echo "$1"
}

cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ icecast 2>/dev/null || true
    pkill -P $$ gwsocket 2>/dev/null || true
    rm -f "$INFOFIFO" 2>/dev/null || true
    exit 1
}

trap cleanup INT TERM EXIT

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    ICECAST_CONF=$(jq -r '.icecast_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    INFOFIFO=$(jq -r '.infofifo' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "ICECAST_CONF: $ICECAST_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "DB_PATH: $DB_PATH"
    log_message "INFOFIFO: $INFOFIFO"
    log_message "===================="
}

download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>"$INFOFIFO"; then
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
    
    icecast -c "$ICECAST_CONF" &
    ICECAST_PID=$!
    log_message "Icecast started with PID: $ICECAST_PID"
    
    sleep 1
    if ! kill -0 $ICECAST_PID 2>/dev/null; then
        log_message "Error: icecast failed to start or crashed immediately"
        log_message "Try running manually: icecast -c $ICECAST_CONF"
        exit 1
    fi
    
    log_message "Icecast is running successfully"
}

get_random_track() {
    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    local random_id=$(shuf -i 1-"$total" -n 1)
    sqlite3 "$DB_PATH" "SELECT path FROM files WHERE id = $random_id;"
}

download_track() {
    local path="$1"
    
    log_message "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" "$DOWNLOADS_DIR/" -v --stats 5s 2>"$INFOFIFO"; then
        log_message "Error: rclone failed to download $path"
        exit 1
    fi
}

kill_process() {
    local pid="$1"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

kill_ffmpeg() {
    if [ -n "$FFMPEG_PID" ]; then
        pkill -P $FFMPEG_PID 2>/dev/null || true
    fi
    FFMPEG_PID=""
}

play_track() {
    local fullname="$1"
    
    ffmpeg -re -i "$fullname" \
        -map 0:a:0 \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -ar 48000 -sample_fmt s16 -ac 2 \
        -c:a flac \
        -compression_level 6 \
        -content_type application/ogg \
        -f ogg \
        icecast://source:hackme@localhost:8000/stream.ogg \
        2>"$INFOFIFO" &
    FFMPEG_PID=$!
    
    if ! wait $FFMPEG_PID; then
        log_message "Error: ffmpeg failed for $fullname"
        kill_ffmpeg
        rm -f "$fullname"
        return 1
    fi
    
    rm -f "$fullname"
    log_message "Finished playing $fullname"
    return 0
}

start_gwsocket() {
    log_message "Creating FIFO and starting gwsocket..."
    rm -f "$INFOFIFO"
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO" &
    GWSOCKET_PID=$!
    log_message "gwsocket started with PID: $GWSOCKET_PID"
}

playback_loop() {
    log_message "Starting music playback loop..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    
    while true; do
        local path=$(get_random_track)
        local fname=${path##*/}
        local fullname="$DOWNLOADS_DIR/$fname"
        
        download_track "$path"
        
        if ! play_track "$fullname"; then
            log_message "Skipping to next track..."
            sleep 1
            continue
        fi
        
        sleep 1
    done

    kill_process "$GWSOCKET_PID"
}

main() {
    load_config
    start_gwsocket
    download_database
    start_icecast
    playback_loop
}

main
