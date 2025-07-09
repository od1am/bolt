#!/usr/bin/env bash

set -euo pipefail

BINARY="zig-out/bin/bolt"
TORRENT_FILE="./torrent/debian-12.11.0-amd64-netinst.iso.torrent"
OUTPUT_DIR="./torrent/output"
TIMEOUT_SECONDS=120
EXPECTED_FILE="$OUTPUT_DIR/debian-12.11.0-amd64-netinst.iso"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_STATUS=0

log_info() { echo -e "[INFO] $1"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; SCRIPT_STATUS=1; }
log_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }

check_requirements() {
    local commands=("zig" "timeout")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command '$cmd' not found. Please install it."
            exit 1
        fi
    done
}

clean_build() {
    if [ -f "$BINARY" ]; then
        log_info "Removing previous build ($BINARY)..."
        rm -f "$BINARY"
    fi
}

build_project() {
    log_info "Building bolt..."
    if ! zig build; then
        log_error "Failed to build bolt"
        exit 1
    fi
    if [ ! -f "$BINARY" ]; then
        log_error "Binary ($BINARY) not found after build"
        exit 1
    fi
    log_success "Build completed successfully"
}

validate_torrent() {
    if [ ! -f "$TORRENT_FILE" ]; then
        log_error "Torrent file ($TORRENT_FILE) not found"
        exit 1
    fi
}

run_download_test() {
    log_info "Starting download test with timeout ($TIMEOUT_SECONDS seconds)..."
    log_info "Using torrent: $TORRENT_FILE"

    if ! timeout "${TIMEOUT_SECONDS}s" "$BINARY" "$TORRENT_FILE" --output-dir "$OUTPUT_DIR"; then
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_warning "Download test timed out after $TIMEOUT_SECONDS seconds"
        else
            log_error "Download process failed with exit code: $exit_code"
        fi
        return $exit_code
    fi
    log_success "Download test completed"
}

validate_downloads() {
    log_info "Checking downloaded files..."
    if [ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
        log_info "Files found in $OUTPUT_DIR:"
        ls -la "$OUTPUT_DIR/"

        if [ -f "$EXPECTED_FILE" ]; then
            local file_size
            file_size=$(wc -c < "$EXPECTED_FILE")
            log_info "Downloaded file size: $file_size bytes"

            if [ "$file_size" -gt 0 ]; then
                log_success "Download successful! File contains data."
                log_info "First 100 characters of downloaded content:"
                head -c 100 "$EXPECTED_FILE"
                echo ""
            else
                log_warning "Downloaded file is empty"
            fi
        else
            log_warning "Expected file ($EXPECTED_FILE) not found"
        fi
    else
        log_warning "No files were downloaded"
    fi
}

main() {
    check_requirements
    clean_build
    build_project
    validate_torrent
    run_download_test
    validate_downloads

    if [ $SCRIPT_STATUS -eq 0 ]; then
        log_success "Build and test completed successfully!"
    else
        log_error "Build and test completed with errors."
        exit $SCRIPT_STATUS
    fi
}

main