#!/bin/bash

set -eu

RSAS_PID=""
GWSOCKET_PID=""
FFMPEG_PID=""

log_message() {
    echo "$1" | tee "$INFOFIFO" 2>/dev/null || echo "$1"
}

cleanup() {
    log_message "Cleaning up..."
    exec 3>&- 2>/dev/null || true
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ rsas 2>/dev/null || true
    pkill -P $$ gwsocket 2>/dev/null || true
    rm -f "$INFOFIFO" "$PCMFIFO" 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM

load_config() {
    local config_file="/music/config.json"

    DB_URL=$(jq -r '.db_url' "$config_file")
    RSAS_CONF=$(jq -r '.rsas_conf' "$config_file")
    DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$config_file")
    RCLONE_CONF=$(jq -r '.rclone_conf' "$config_file")
    INFOFIFO=$(jq -r '.infofifo' "$config_file")
    DB_PATH=$(jq -r '.db_path' "$config_file")
    PCMFIFO=$(jq -r '.pcmfifo' "$config_file")

    log_message "=== Configuration ==="
    log_message "DB_URL: $DB_URL"
    log_message "RSAS_CONF: $RSAS_CONF"
    log_message "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    log_message "RCLONE_CONF: $RCLONE_CONF"
    log_message "DB_PATH: $DB_PATH"
    log_message "INFOFIFO: $INFOFIFO"
    log_message "PCMFIFO: $PCMFIFO"
    log_message "===================="
}

download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>&1 | tee "$INFOFIFO"; then
        log_message "Error: Failed to download database from $DB_URL"
        exit 1
    fi
}

start_rsas() {
    log_message "Starting rsas with config: $RSAS_CONF"

    if [ ! -f "$RSAS_CONF" ]; then
        log_message "Error: Config file not found: $RSAS_CONF"
        exit 1
    fi

    rsas -c "$RSAS_CONF" 2>&1 | tee "$INFOFIFO" &
    RSAS_PID=$!
    log_message "rsas started with PID: $RSAS_PID"

    sleep 2
    if ! kill -0 $RSAS_PID 2>/dev/null; then
        log_message "Error: rsas failed to start or crashed immediately"
        exit 1
    fi

    log_message "rsas is running successfully"
}

start_ffmpeg() {
    exec 3>&- 2>/dev/null || true
    
    rm -f "$PCMFIFO"
    mkfifo "$PCMFIFO"

    log_message "Starting ffmpeg encoder..."

    ffmpeg -nostdin -hide_banner -loglevel error \
        -f s16le -ar 48000 -ac 2 -i "$PCMFIFO" \
        -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0,arealtime" \
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
    local total
    total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    if [ "$total" -eq 0 ]; then
        log_message "Error: No tracks in database"
        exit 1
    fi
    local random_id
    random_id=$(shuf -i 1-"$total" -n 1)
    sqlite3 "$DB_PATH" "SELECT path FROM files WHERE id = $random_id;"
}

get_local_filename() {
    local remote_path="$1"
    local filename="${remote_path##*/}"
    echo "$DOWNLOADS_DIR/$filename"
}

download_track_async() {
    local remote_path="$1"
    local local_file="$2"
    local filename="${remote_path##*/}"
    
    log_message "Pre-buffering: $remote_path"
    (
        if rclone --config "$RCLONE_CONF" copy "$remote_path" \
            "$DOWNLOADS_DIR/" -v --stats 5s 2>&1 | tee "$INFOFIFO"; then
            log_message "Pre-buffer complete: $filename"
        else
            log_message "Pre-buffer failed: $filename"
            rm -f "$local_file"
        fi
    ) &
    echo $!
}

download_track_sync() {
    local remote_path="$1"
    log_message "Downloading: $remote_path"
    
    if rclone --config "$RCLONE_CONF" copy "$remote_path" \
        "$DOWNLOADS_DIR/" -v --stats 5s 2>&1 | tee "$INFOFIFO"; then
        return 0
    else
        log_message "Error: Download failed"
        return 1
    fi
}

stream_track() {
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
    
    log_message "Format: $audio_format"

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
            ffmpeg -nostdin -hide_banner \
                -i "$local_file" -map 0:a:0 \
                -f s16le -ar 48000 -ac 2 - 2>"$INFOFIFO" \
                > "$PCMFIFO"
            stream_result=$?
            ;;
    esac

    rm -f "$local_file"

    if [ $stream_result -ne 0 ]; then
        log_message "Error: Streaming failed"
        return 1
    fi

    log_message "Streaming complete"
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

insert_silence() {
    local duration_sec="${1:-5}"
    local bytes=$((48000 * 2 * 2 * duration_sec))
    log_message "Inserting ${duration_sec}s silence"
    dd if=/dev/zero bs="$bytes" count=1 2>/dev/null > "$PCMFIFO"
}

check_ffmpeg() {
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "FFmpeg died, restarting..."
        start_ffmpeg
    fi
}

start_next_download() {
    local remote_path next_file
    remote_path=$(get_random_track)
    next_file=$(get_local_filename "$remote_path")
    echo "$next_file"
    download_track_async "$remote_path" "$next_file"
}

handle_stream_failure() {
    local next_file="$1"
    log_message "Streaming failed, checking next track..."
    if [ ! -f "$next_file" ]; then
        log_message "Next track not ready, inserting silence..."
        insert_silence 5
    fi
}

handle_missing_next_track() {
    local remote_path current_file
    log_message "Next track unavailable, emergency download..."
    insert_silence 2
    
    remote_path=$(get_random_track)
    current_file=$(get_local_filename "$remote_path")
    
    if download_track_sync "$remote_path"; then
        echo "$current_file"
        return 0
    else
        log_message "Emergency download failed"
        insert_silence 8
        return 1
    fi
}

prepare_initial_track() {
    local remote_path current_file
    remote_path=$(get_random_track)
    current_file=$(get_local_filename "$remote_path")
    
    log_message "Initial download: $remote_path"
    if download_track_sync "$remote_path"; then
        echo "$current_file"
        return 0
    fi
    
    log_message "Initial download failed, retrying..."
    insert_silence 5
    
    remote_path=$(get_random_track)
    current_file=$(get_local_filename "$remote_path")
    if download_track_sync "$remote_path"; then
        echo "$current_file"
        return 0
    fi
    
    log_message "Error: Initial download failed twice"
    return 1
}

playback_loop() {
    log_message "Starting playback loop with pre-buffering..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null || true

    local current_file next_file download_pid
    
    current_file=$(prepare_initial_track) || exit 1

    while true; do
        # Start pre-buffering next track
        read -r next_file download_pid <<< "$(start_next_download)"
        
        check_ffmpeg
        
        # Stream current track
        if [ -f "$current_file" ]; then
            if ! stream_track "$current_file"; then
                wait $download_pid 2>/dev/null
                handle_stream_failure "$next_file"
            fi
        else
            log_message "Current file missing, skipping..."
            wait $download_pid 2>/dev/null
        fi

        # Wait for pre-buffer to complete
        wait $download_pid 2>/dev/null
        
        # Switch to next track or handle missing track
        if [ -f "$next_file" ]; then
            current_file="$next_file"
            log_message "Switching to: $current_file"
        else
            current_file=$(handle_missing_next_track) || continue
        fi

        sleep 1
    done
}

main() {
    load_config
    start_gwsocket
    download_database
    start_rsas
    start_ffmpeg
    playback_loop
}

main
