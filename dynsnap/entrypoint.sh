#!/bin/ash

set -eu

ICECAST_PID=""
GWSOCKET_PID=""
INFOFIFO=""
FFMPEG_PID=""

log_message() {
    echo "$1"
    if [ -n "$INFOFIFO" ] && [ -p "$INFOFIFO" ]; then
        echo "$1" > "$INFOFIFO" 2>/dev/null || true
    fi
}

cleanup() {
    log_message "Cleaning up..."
    exec 3>&- 2>/dev/null || true
    
    # Kill processes using stored PIDs
    [ -n "$FFMPEG_PID" ] && kill $FFMPEG_PID 2>/dev/null || true
    [ -n "$ICECAST_PID" ] && kill $ICECAST_PID 2>/dev/null || true
    [ -n "$GWSOCKET_PID" ] && kill $GWSOCKET_PID 2>/dev/null || true
    
    # Fallback to pkill
    pkill -P $$ 2>/dev/null || true
    
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
    log_message "Downloading database from $DB_URL..."
    if [ -n "$INFOFIFO" ] && [ -p "$INFOFIFO" ]; then
        wget -O "$DB_PATH" "$DB_URL" 2>&1 | tee "$INFOFIFO"
    else
        wget -O "$DB_PATH" "$DB_URL" 2>&1
    fi
    
    if [ $? -ne 0 ]; then
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
    
    icecast -c "$ICECAST_CONF" 2>&1 | tee "$INFOFIFO" &
    ICECAST_PID=$!
    log_message "Icecast started with PID: $ICECAST_PID"
    
    sleep 2
    if ! kill -0 $ICECAST_PID 2>/dev/null; then
        log_message "Error: icecast failed to start or crashed immediately"
        exit 1
    fi
    
    log_message "Icecast is running successfully"
}

start_ffmpeg() {
    exec 3>&- 2>/dev/null || true
    
    rm -f "$PCMFIFO"
    mkfifo "$PCMFIFO"

    log_message "Starting ffmpeg encoder..."

    ffmpeg -nostdin -hide_banner -loglevel warning -re \
        -f s16le -ar 48000 -ac 2 -i "$PCMFIFO" \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        -ar 48000 -sample_fmt s16 -ac 2 \
        -c:a flac -compression_level 6 \
        -f ogg -content_type application/ogg \
        icecast://source:hackme@localhost:8000/stream.ogg &
    FFMPEG_PID=$!
    log_message "FFmpeg started with PID: $FFMPEG_PID"
    
    sleep 1
    if ! kill -0 $FFMPEG_PID 2>/dev/null; then
        log_message "Error: ffmpeg failed to start"
        exit 1
    fi
    
    exec 3>"$PCMFIFO"
    log_message "FIFO holder established"
}

get_random_track() {
    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    if [ "$total" -eq 0 ]; then
        log_message "Error: No tracks in database"
        return 1
    fi
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
    local local_file="$1"

    if [ ! -f "$local_file" ]; then
        log_message "Error: File not found: $local_file"
        return 1
    fi

    log_message "Streaming: $local_file"

    local audio_format
    audio_format=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$local_file" 2>/dev/null)
    
    if [ -z "$audio_format" ]; then
        log_message "Error: Could not determine audio format"
        rm -f "$local_file"
        return 1
    fi
    
    log_message "Detected format: $audio_format"

    local stream_result=0
    case "$audio_format" in
        opus)
            opusdec --rate 48000 --force-stereo \
                "$local_file" - 2>"$INFOFIFO" > "$PCMFIFO"
            stream_result=$?
            ;;
        mp3)
            mpg123 --rate 48000 --encoding s16 \
                --stereo --long-tag -v -s "$local_file" \
                2>"$INFOFIFO" > "$PCMFIFO"
            stream_result=$?
            ;;
        *)
            log_message "Format $audio_format detected"
            ffmpeg -nostdin -hide_banner \
                -i "$local_file" -map 0:a:0 \
                -f s16le -ar 48000 -ac 2 - 2>"$INFOFIFO" \
                > "$PCMFIFO"
            stream_result=$?
            ;;
    esac

    rm -f "$local_file"

    if [ $stream_result -ne 0 ]; then
        log_message "Error: Streaming failed for $local_file"
        return 1
    fi

    log_message "Finished streaming: $local_file"
    return 0
}

start_gwsocket() {
    log_message "Creating FIFO and starting gwsocket..."
    rm -f "$INFOFIFO"
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO" &
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
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true
    
    while true; do
        local path=$(get_random_track)
        if [ -z "$path" ]; then
            log_message "Error: Failed to get random track"
            sleep 5
            continue
        fi
        
        local fname=${path##*/}
        if [ -z "$fname" ]; then
            log_message "Error: Failed to extract filename from path"
            sleep 2
            continue
        fi
        
        local fullname="$DOWNLOADS_DIR/$fname"
        log_message "Selected track: $fname"
        
        if ! download_track "$path"; then
            log_message "Download failed, skipping to next track..."
            sleep 2
            continue
        fi

        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
            log_message "FFmpeg died, restarting..."
            start_ffmpeg
        fi
        
        if ! play_track "$fullname"; then
            log_message "Playback failed, skipping to next track..."
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
