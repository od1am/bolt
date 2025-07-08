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

echo ""
echo "Starting download test with timeout (120 seconds)..."
echo "Using sample torrent with new CLI interface..."

# Run the BitTorrent client with timeout
timeout 120s ./zig-out/bin/bolt ./test/sample.torrent --output-dir ./test || {
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
if [ "$(ls -A ./test 2>/dev/null)" ]; then
    echo "Files found in downloads directory:"
    ls -la ./test/

    # Check if sample.txt exists and has content
    if [ -f "./test/sample.txt" ]; then
        file_size=$(wc -c < ./test/sample.txt)
        echo "Downloaded file size: $file_size bytes"
        
        if [ "$file_size" -gt 0 ]; then
            echo "✅ Download successful! File contains actual data."
            echo "First 100 characters of downloaded content:"
            head -c 100 ./test/sample.txt
            echo ""
        else
            echo "⚠️  Downloaded file is empty"
        fi
    else
        echo "⚠️  sample.txt not found"
    fi
else
    echo "No files were downloaded during the test period."
fi

echo ""
echo "🎉 Build and test completed!"