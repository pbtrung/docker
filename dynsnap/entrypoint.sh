#!/bin/ash

# Exit on error
set -eu

# Global variables for process tracking
SNAPSERVER_PID=""
GWSOCKET_PID=""
PIPELINE_PID=""

# Logging function (defined early for use throughout)
log_message() {
    echo "$1" | tee "$INFOFIFO" 2>/dev/null || echo "$1"
}

# Cleanup function
cleanup() {
    log_message "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ snapserver 2>/dev/null || true
    pkill -P $$ gwsocket 2>/dev/null || true
    rm -f "$INFOFIFO" 2>/dev/null || true  # Remove FIFO on cleanup
    exit 1
}

# Set trap for cleanup on exit/error
trap cleanup INT TERM EXIT

# Load configuration from JSON file
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

# Download database from URL
download_database() {
    log_message "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>"$INFOFIFO"; then
        log_message "Error: Failed to download database from $DB_URL"
        exit 1
    fi
}

# Start snapserver and verify it's running
start_snapserver() {
    log_message "Starting snapserver with config: $SNAPSERVER_CONF"
    
    if [ ! -f "$SNAPSERVER_CONF" ]; then
        log_message "Error: Config file not found: $SNAPSERVER_CONF"
        exit 1
    fi
    
    # snapserver --config "$SNAPSERVER_CONF" &
    icecast -c "$SNAPSERVER_CONF" &
    SNAPSERVER_PID=$!
    log_message "Snapserver started with PID: $SNAPSERVER_PID"
    
    sleep 1
    if ! kill -0 $SNAPSERVER_PID 2>/dev/null; then
        log_message "Error: snapserver failed to start or crashed immediately"
        log_message "Try running manually: snapserver --config $SNAPSERVER_CONF"
        exit 1
    fi
    
    log_message "Snapserver is running successfully"
}

# Get a random track from the database
get_random_track() {
    local total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    local random_id=$(shuf -i 1-"$total" -n 1)
    sqlite3 "$DB_PATH" "SELECT path FROM files WHERE id = $random_id;"
}

# Download track using rclone
download_track() {
    local path="$1"
    
    log_message "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" "$DOWNLOADS_DIR/" -v --stats 5s 2>"$INFOFIFO"; then
        log_message "Error: rclone failed to download $path"
        exit 1
    fi
}

# Kill process helper
kill_process() {
    local pid="$1"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# Kill pipeline processes
kill_pipeline() {
    if [ -n "$PIPELINE_PID" ]; then
        pkill -P $PIPELINE_PID 2>/dev/null || true
    fi
    PIPELINE_PID=""
}

process_gst_output() {
    stdbuf -oL awk '
        /^FOUND TAG/ {
            # Skip FOUND TAG lines
            next
        }
        /^[0-9]+:[0-9]{2}:[0-9]{2}\.[0-9] \/ [0-9]+:[0-9]{2}:[0-9]{2}\.[0-9]/ {
            # Progress update: overwrite the same line
            printf "\r%s", $0
            fflush()
            progress_seen = 1
            next
        }
        {
            # Skip duplicate lines (e.g., repeated metadata blocks)
            if ($0 == prev_line) {
                next
            }
            
            # Before printing metadata, ensure it starts on a new line
            # But skip double newline if we are still in the initial pipeline setup
            if (progress_seen) {
                if (prev_line !~ /^Setting pipeline to PLAYING/) {
                    printf "\n\n"
                } else {
                    printf "\n"
                }
                progress_seen = 0
            }
            print
            fflush()
            prev_line = $0
        }
        END {
            # Ensure final newline at end of decoding
            if (progress_seen)
                printf "\n\n"
            fflush()
        }
    '
}

# Play a single track
play_track() {
    local fullname="$1"
    # local gain_value
    
    # log_message "Analyzing ReplayGain for $fullname ..."
    
    # gain_value=$(ffmpeg -y -t 120 -i "$fullname" \
    #     -af "aformat=sample_rates=22050:channel_layouts=mono,replaygain" \
    #     -f null - 2>&1 | \
    #     grep -oP 'track_gain = \K[+-]?[0-9]+\.?[0-9]*' | \
    #     head -n 1)
        
    # gain_value=${gain_value#+}
    # if [[ -z "$gain_value" ]]; then
    #     log_message "Warning: Could not determine gain_value, using 0 dB"
    #     gain_value=0
    # fi
    
    # log_message "Calculated track_gain: ${gain_value} dB"
    # log_message "Applying ReplayGain: ${gain_value} dB"
    
    # gst-launch-1.0 -e -t --force-position playbin3 uri="file://$fullname" \
    #     audio-sink="audioresample ! audioconvert ! \
    #                 rgvolume album-mode=false pre-amp=0.0 fallback-gain=${gain_value} ! \
    #                 audio/x-raw,rate=48000,channels=2,format=S16LE ! \
    #                 filesink location=$SNAPFIFO" \
    #     2>&1 | process_gst_output > "$INFOFIFO" &

    ffmpeg -re -i "$fullname" \
        -map 0:a:0 \
        -c:a copy \
        -f ogg \
        -content_type application/ogg \
        icecast://source:hackme@localhost:8000/stream.ogg \
        2>"$INFOFIFO" &
    PIPELINE_PID=$!
    
    if ! wait $PIPELINE_PID; then
        log_message "Error: pipeline failed for $fullname"
        kill_pipeline
        rm -f "$fullname"
        return 1
    fi
    
    rm -f "$fullname"
    log_message "Finished playing $fullname"
    return 0
}

# Start gwsocket with FIFO
start_gwsocket() {
    log_message "Creating FIFO and starting gwsocket..."
    rm -f "$INFOFIFO"  # Remove existing FIFO if present
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO" &
    GWSOCKET_PID=$!
    log_message "gwsocket started with PID: $GWSOCKET_PID"
}

# Main playback loop
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

# Main execution
main() {
    load_config
    start_gwsocket
    download_database
    start_snapserver
    playback_loop
}

main
