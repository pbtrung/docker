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
    rm -f "$INFOFIFO" "$PCMFIFO" 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM

load_config() {
    local config_file="/music/config.json"
    
    DB_URL=$(jq -r '.db_url' "$config_file")
    ICECAST_CONF=$(jq -r '.icecast_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    INFOFIFO=$(jq -r '.infofifo' "$config_file")
    PCMFIFO=$(jq -r '.pcmfifo' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    
    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "ICECAST_CONF: $ICECAST_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "DB_PATH: $DB_PATH"
    log_message "INFOFIFO: $INFOFIFO"
    log_message "PCMFIFO: $PCMFIFO"
    log_message "===================="
}

download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>&1 \
        | tee "$INFOFIFO"; then
        log_message \
            "Error: Failed to download database from $DB_URL"
        exit 1
    fi
}

start_icecast() {
    log_message "Starting icecast with config: $ICECAST_CONF"
    
    if [ ! -f "$ICECAST_CONF" ]; then
        log_message \
            "Error: Config file not found: $ICECAST_CONF"
        exit 1
    fi
    
    icecast -c "$ICECAST_CONF" 2>&1 | tee "$INFOFIFO" &
    ICECAST_PID=$!
    log_message "Icecast started with PID: $ICECAST_PID"
    
    sleep 2
    if ! kill -0 $ICECAST_PID 2>/dev/null; then
        log_message \
            "Error: icecast failed to start or crashed immediately"
        exit 1
    fi
    
    log_message "Icecast is running successfully"
}

start_ffmpeg() {
    rm -f "$PCMFIFO"
    mkfifo "$PCMFIFO"

    log_message "Starting ffmpeg encoder..."
    ffmpeg -nostdin -hide_banner -loglevel error -re \
        -f s16le -ar 48000 -ac 2 -i "$PCMFIFO" \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -ar 48000 -sample_fmt s16 -ac 2 \
        -c:a flac -compression_level 6 \
        -f ogg -content_type audio/ogg \
        icecast://source:hackme@localhost:8000/stream.ogg &
    FFMPEG_PID=$!
    log_message "FFmpeg started with PID: $FFMPEG_PID"
    
    sleep 1
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        log_message "Error: ffmpeg failed to start"
        exit 1
    fi
}

get_random_track() {
    local total=$(sqlite3 "$DB_PATH" \
        "SELECT COUNT(*) FROM files;")
    if [ "$total" -eq 0 ]; then
        log_message "Error: No tracks in database"
        exit 1
    fi
    local random_id=$(shuf -i 1-"$total" -n 1)
    sqlite3 "$DB_PATH" \
        "SELECT path FROM files WHERE id = $random_id;"
}

download_track() {
    local path="$1"
    
    log_message "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" \
        "$DOWNLOADS_DIR/" -v --stats 5s 2>&1 \
        | tee "$INFOFIFO"; then
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
    
    log_message "Playing: $fullname"
    
    local format=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$fullname" 2>/dev/null)
    
    if [ -z "$format" ]; then
        log_message "Error: Could not determine audio format"
        rm -f "$fullname"
        return 1
    fi
    
    log_message "Detected format: $format"
    
    case "$format" in
        opus)
            if ! opusdec --rate 48000 --force-stereo \
                "$fullname" - 2>"$INFOFIFO" > "$PCMFIFO"; then
                log_message "Error: opusdec failed"
                rm -f "$fullname"
                return 1
            fi
            ;;
        mp3)
            if ! mpg123 --rate 48000 --encoding s16 \
                --stereo -s "$fullname" 2>"$INFOFIFO" \
                > "$PCMFIFO"; then
                log_message "Error: mpg123 failed"
                rm -f "$fullname"
                return 1
            fi
            ;;
        *)
            log_message \
                "Unsupported format: $format (converting with ffmpeg)"
            if ! ffmpeg -nostdin -hide_banner \
                -loglevel error -i "$fullname" \
                -f s16le -ar 48000 -ac 2 - 2>"$INFOFIFO" \
                > "$PCMFIFO"; then
                log_message "Error: ffmpeg conversion failed"
                rm -f "$fullname"
                return 1
            fi
            ;;
    esac
    
    rm -f "$fullname"
    log_message "Finished playing: $fullname"
    return 0
}

start_gwsocket() {
    log_message "Creating FIFO and starting gwsocket..."
    rm -f "$INFOFIFO"
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std \
        < "$INFOFIFO" &
    GWSOCKET_PID=$!
    log_message "gwsocket started with PID: $GWSOCKET_PID"
    
    sleep 1
    if ! kill -0 $GWSOCKET_PID 2>/dev/null; then
        log_message "Error: gwsocket failed to start"
        exit 1
    fi
}

playback_loop() {
    log_message "Starting music playback loop..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete \
        2>/dev/null || true
    
    while true; do
        local path=$(get_random_track)
        local fname=${path##*/}
        local fullname="$DOWNLOADS_DIR/$fname"
        
        if ! download_track "$path"; then
            log_message \
                "Download failed, skipping to next track..."
            sleep 2
            continue
        fi
        
        if ! play_track "$fullname"; then
            log_message \
                "Playback failed, skipping to next track..."
            sleep 2
            continue
        fi
        
        sleep 1
    done
}

main() {
    load_config
    start_gwsocket
    download_database
    start_icecast
    start_ffmpeg
    playback_loop
}

main
