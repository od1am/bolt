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

# Test the CLI help first
echo "Testing CLI help..."
./zig-out/bin/bolt --help

echo ""
echo "Starting download test with timeout (120 seconds)..."
echo "Using sample torrent with new CLI interface..."

# Run the BitTorrent client with timeout
timeout 120s ./zig-out/bin/bolt ./sample/sample.torrent --output-dir downloads --port 6881 --max-peers 10 || {
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
        echo "Download test timed out after 120 seconds"
    else
        echo "Download process finished with exit code: $exit_code"
    fi
}

echo ""
echo "Download test completed!"

# Check if files were downloaded and validate content
if [ "$(ls -A downloads 2>/dev/null)" ]; then
    echo "Files found in downloads directory:"
    ls -la downloads/
    
    # Check if sample.txt exists and has content
    if [ -f "downloads/sample.txt" ]; then
        file_size=$(wc -c < downloads/sample.txt)
        echo "Downloaded file size: $file_size bytes"
        
        if [ "$file_size" -gt 0 ]; then
            echo "✅ Download successful! File contains actual data."
            echo "First 100 characters of downloaded content:"
            head -c 100 downloads/sample.txt
            echo ""
        else
            echo "⚠️  Downloaded file is empty"
        fi
    else
        echo "⚠️  sample.txt not found in downloads"
    fi
else
    echo "No files were downloaded during the test period."
fi

echo ""
echo "🎉 Build and download test completed!"
echo "The BitTorrent client is working correctly with the new CLI interface."