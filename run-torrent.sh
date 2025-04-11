#!/usr/bin/env bash

# Exit on error
set -e

# Always build from scratch
[ -f "zig-out/bin/bolt" ] && rm zig-out/bin/bolt
echo "Building bolt..."
zig build
if [ ! -f "zig-out/bin/bolt" ]; then
    echo "Failed to build bolt"
    exit 1
fi

# Create downloads directory if it doesn't exist
mkdir -p downloads

# Run the BitTorrent client with the torrent file
echo "Starting download..."
./zig-out/bin/bolt -t /home/zor/projects/bolt/torrent-file/big-buck-bunny.torrent -o downloads

echo "Download completed!" 

# Check if the download is complete
if [ -f "downloads/big-buck-bunny.torrent" ]; then
    echo "Download is complete!"
else
    echo "Download is not complete!"
fi
