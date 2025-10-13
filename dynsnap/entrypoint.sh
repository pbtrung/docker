#!/bin/ash

# Exit on error
set -eu

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    pkill -P $$ ffmpeg 2>/dev/null || true
    pkill -P $$ snapserver 2>/dev/null || true
    exit 1
}

# Set trap for cleanup on exit/error
trap cleanup INT TERM EXIT

# Read config from JSON
CONFIG_FILE="/music/config.json"
DB_URL=$(jq -r '.db_url' "$CONFIG_FILE")
SNAPSERVER_CONF=$(jq -r '.snapserver_conf' "$CONFIG_FILE")
DOWNLOADS_DIR=$(jq -r '.downloads_dir' "$CONFIG_FILE")
RCLONE_CONF=$(jq -r '.rclone_conf' "$CONFIG_FILE")
SNAPFIFO=$(jq -r '.snapfifo' "$CONFIG_FILE")
DB_PATH=$(jq -r '.db_path' "$CONFIG_FILE")

# Debug: Print configuration
echo "=== Configuration ==="
echo "DB_URL: $DB_URL"
echo "SNAPSERVER_CONF: $SNAPSERVER_CONF"
echo "DOWNLOADS_DIR: $DOWNLOADS_DIR"
echo "RCLONE_CONF: $RCLONE_CONF"
echo "SNAPFIFO: $SNAPFIFO"
echo "DB_PATH: $DB_PATH"
echo "===================="

# Download SQLite database with error handling
echo "Downloading database..."
if ! wget -O "$DB_PATH" "$DB_URL"; then
    echo "Error: Failed to download database from $DB_URL"
    exit 1
fi

# Start snapserver with error handling
echo "Starting snapserver..."
if ! snapserver --config "$SNAPSERVER_CONF" & then
    echo "Error: Failed to start snapserver"
    exit 1
fi
SNAPSERVER_PID=$!

# Check if snapserver is still running
sleep 1
if ! kill -0 $SNAPSERVER_PID 2>/dev/null; then
    echo "Error: snapserver failed to start"
    exit 1
fi

echo "Starting music playback loop..."
while true; do
    # Get total number of rows
    total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM files;")
    
    # Get random row id between 1 and total
    random_id=$(shuf -i 1-"$total" -n 1)
    
    # Get path from random row
    path=$(sqlite3 "$DB_PATH" "SELECT path FROM files WHERE id = $random_id;")
    
    fname=${path##*/}
    fullname="$DOWNLOADS_DIR/$fname"

    # Download file with rclone and error handling
    echo "Downloading: $path"
    if ! rclone --config "$RCLONE_CONF" copy "$path" "$DOWNLOADS_DIR/" -v --stats 5s; then
        echo "Error: rclone failed to download $path"
        exit 1
    fi

    # Use a subshell with pipes and error handling
    # Start ffmpeg in background and get its PID
    (
        set -o pipefail
        opusdec "$fullname" --rate 48000 --force-stereo - | \
        ffmpeg -y \
          -f s16le -ac 2 -ar 48000 -i - \
          -af "dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
          -f s16le -ac 2 -ar 48000 "$SNAPFIFO" \
          -hide_banner -loglevel error
    ) &
    
    PIPELINE_PID=$!
    
    # Wait for the pipeline to complete
    if ! wait $PIPELINE_PID; then
        echo "Error: opusdec or ffmpeg failed for $fullname"
        # Kill any remaining processes from the pipeline
        pkill -P $PIPELINE_PID 2>/dev/null || true
        rm -f "$fullname"
        # Continue to next track instead of exiting
        sleep 1
        continue
    fi
    
    # Cleanup downloaded file
    rm -f "$fullname"

    sleep 1
done