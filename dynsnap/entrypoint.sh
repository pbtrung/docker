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
    DB_PATH=$(jq -r '.db_path // "/music/files.db"' "$config_file")
    
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

# Play a single track
play_track() {
    local fullname="$1"
    
    (
        set -o pipefail

        # opusdec --rate 48000 --force-stereo --gain -3 "$fullname" "$SNAPFIFO" 2>"$INFOFIFO"
        # opusdec --rate 48000 --force-stereo 2>"$INFOFIFO" "$fullname" - | \
        # ffmpeg -y \
        #   -f s16le -ac 2 -ar 48000 -i - \
        #   -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
        #   -f s16le -ac 2 -ar 48000 "$SNAPFIFO" \
        #   -hide_banner -loglevel error

        gain=$(opusdec --rate 48000 --force-stereo --force-wav --quiet "$fullname" - | wavegain --fast - 2>&1 | awk '/^\s*-?[0-9]+\.[0-9]+.*dB/{print $1}')
        # Check if gain extraction succeeded
        if [[ -z "$gain" ]]; then
            echo "Error: Failed to calculate gain for $fullname" >&2
            gain=0
        fi
        # Invert the gain (if wavegain says -5.84, we need +5.84)
        gain_inverted=$(awk "BEGIN {print -1 * $gain}")
        opusdec --rate 48000 --force-stereo --gain -3 "$fullname" "$SNAPFIFO" 2>"$INFOFIFO"
    ) &
    PIPELINE_PID=$!
    
    # Wait for the pipeline to complete
    if ! wait $PIPELINE_PID; then
        echo "Error: opusdec or ffmpeg failed for $fullname"
        kill_pipeline
        rm -f "$fullname"
        return 1
    fi
    
    # Pipeline completed successfully
    rm -f "$fullname"
    return 0
}

# Start gwsocket with FIFO
start_gwsocket() {
    echo "Creating FIFO and starting gwsocket..."
    mkfifo "$INFOFIFO"
    (gwsocket --port=9000 --addr=0.0.0.0 --std < "$INFOFIFO") &
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
