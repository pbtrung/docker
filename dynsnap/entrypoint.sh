#!/bin/ash

# Exit on error
set -eu

# Global variables for process tracking
SNAPSERVER_PID=""
GWSOCKET_PID=""
PIPELINE_PID=""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ snapserver 2>/dev/null || true
    pkill -P $$ gwsocket 2>/dev/null || true
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
    
    echo "=== Configuration ==="
    echo "DB_URL: $DB_URL"
    echo "SNAPSERVER_CONF: $SNAPSERVER_CONF"
    echo "DOWNLOADS_DIR: $DOWNLOADS_DIR"
    echo "RCLONE_CONF: $RCLONE_CONF"
    echo "SNAPFIFO: $SNAPFIFO"
    echo "DB_PATH: $DB_PATH"
    echo "INFOFIFO: $INFOFIFO"
    echo "===================="
}

# Download database from URL
download_database() {
    echo "Downloading database..."
    if ! wget -O "$DB_PATH" "$DB_URL" 2>"$INFOFIFO"; then
        echo "Error: Failed to download database from $DB_URL"
        exit 1
    fi
}

# Start snapserver and verify it's running
start_snapserver() {
    echo "Starting snapserver with config: $SNAPSERVER_CONF"
    
    if [ ! -f "$SNAPSERVER_CONF" ]; then
        echo "Error: Config file not found: $SNAPSERVER_CONF"
        exit 1
    fi
    
    echo "Config file exists, starting snapserver..."
    snapserver --config "$SNAPSERVER_CONF" &
    SNAPSERVER_PID=$!
    echo "Snapserver started with PID: $SNAPSERVER_PID"
    
    sleep 1
    if ! kill -0 $SNAPSERVER_PID 2>/dev/null; then
        echo "Error: snapserver failed to start or crashed immediately"
        echo "Config file: $SNAPSERVER_CONF"
        echo "Check snapserver logs for details"
        echo "Try running manually: snapserver --config $SNAPSERVER_CONF"
        exit 1
    fi
    
    echo "Snapserver is running successfully"
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
    
    echo "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" "$DOWNLOADS_DIR/" -v --stats 5s 2>"$INFOFIFO"; then
        echo "Error: rclone failed to download $path"
        exit 1
    fi
}

# Kill gwsocket process
kill_gwsocket() {
    if [ -n "$GWSOCKET_PID" ]; then
        kill $GWSOCKET_PID 2>/dev/null || true
        wait $GWSOCKET_PID 2>/dev/null || true
        GWSOCKET_PID=""
    fi
}

# Kill pipeline processes
kill_pipeline() {
    if [ -n "$PIPELINE_PID" ]; then
        pkill -P $PIPELINE_PID 2>/dev/null || true
        PIPELINE_PID=""
    fi
}

process_gst_output() {
    stdbuf -oL awk '
        /^[0-9]+:[0-9]{2}:[0-9]{2}\.[0-9] \/ [0-9]+:[0-9]{2}:[0-9]{2}\.[0-9]/ {
            # Progress update: overwrite the same line
            printf "\r%s", $0
            fflush()
            progress_seen = 1
            next
        }

        {
            # Before printing metadata, ensure it starts on a new line
            if (progress_seen) {
                printf "\n\n"
                progress_seen = 0
            }
            print
            fflush()
        }

        END {
            # Ensure final newline at end of decoding
            if (progress_seen)
                printf "\n\n"
            fflush()
        }
    '
}

log_message() {
    echo "$1" | tee "$INFOFIFO"
}

# Play a single track
play_track() {
    local fullname="$1"
    local gain_value linear_gain
    
    log_message "Analyzing loudness for $fullname ..."
    
    gain_value=$(ffmpeg -y -t 60 -i "$fullname" \
        -af loudnorm=I=-16:print_format=json \
        -f null - 2>&1 | \
        awk '/^\{/,/^\}/' | jq -r ".target_offset")
    
    if [[ -z "$gain_value" || "$gain_value" == "null" ]]; then
        log_message "Warning: Could not determine gain_value, using 0 dB"
        gain_value=0
    fi
    
    log_message "Calculated gain_value: ${gain_value} dB"
    
    linear_gain=$(echo "scale=10; e(l(10)*$gain_value/20)" | bc -l 2>/dev/null)
    
    if [[ -z "$linear_gain" || "$linear_gain" == "." || "$linear_gain" == "0" ]]; then
        log_message "Warning: invalid conversion, defaulting to 1.0x gain"
        linear_gain="1.0"
    fi
    
    log_message "Applying linear gain factor: ${linear_gain}"
    
    gst-launch-1.0 -e -t --force-position playbin3 uri="file://$fullname" \
        audio-sink="audioresample ! audioconvert ! \
                    audioamplify amplification=${linear_gain} clipping-method=clip ! \
                    audio/x-raw,rate=48000,channels=2,format=S16LE ! \
                    filesink location=$SNAPFIFO" \
        2>&1 | process_gst_output >"$INFOFIFO" &
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
    echo "Creating FIFO and starting gwsocket..."
    mkfifo "$INFOFIFO"
    gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO" &
    GWSOCKET_PID=$!
    echo "gwsocket started with PID: $GWSOCKET_PID"
}

# Main playback loop
playback_loop() {
    echo "Starting music playback loop..."
    find "$DOWNLOADS_DIR" -maxdepth 1 -type f -delete 2>/dev/null
    
    while true; do
        local path=$(get_random_track)
        local fname=${path##*/}
        local fullname="$DOWNLOADS_DIR/$fname"
        
        download_track "$path"
        
        if ! play_track "$fullname"; then
            echo "Skipping to next track..."
            sleep 1
            continue
        fi
        
        sleep 1
    done

    kill_gwsocket
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
