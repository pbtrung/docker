#!/bin/ash
set -e

cleanup() {
    echo "Shutting down services..."
    kill -TERM "$SNAPSERVER_PID" 2>/dev/null || true
    kill -TERM "$LIBRESPOT_PID" 2>/dev/null || true
    wait
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Validate required files/directories
if [ ! -f "/music/snapserver.conf" ]; then
    echo "ERROR: snapserver.conf not found at /music/snapserver.conf"
    exit 1
fi

# Create required directories
mkdir -p /music/oauth

# Ensure the named pipe exists for snapserver
if [ ! -p /tmp/snapfifo ]; then
    mkfifo /tmp/snapfifo
fi

# Start snapserver in background
echo "Starting snapserver..."
snapserver --config "/music/snapserver.conf" &
SNAPSERVER_PID=$!

# Give snapserver a moment to start
sleep 2

# Check if snapserver started successfully
if ! kill -0 "$SNAPSERVER_PID" 2>/dev/null; then
    echo "ERROR: snapserver failed to start"
    exit 1
fi

echo "Starting librespot..."
librespot --name music \
    --cache /music/oauth \
    --enable-oauth \
    --backend pipe \
    --device /tmp/snapfifo \
    --bitrate 320 \
    --autoplay on \
    --initial-volume 100 \
    --cache-size-limit 100M \
    --enable-volume-normalisation \
    --normalisation-gain-type track &

LIBRESPOT_PID=$!

# Wait for both processes
wait
