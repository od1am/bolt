# Bolt BitTorrent Client

A BitTorrent client written in Zig, featuring support for both HTTP and UDP trackers, multi-file torrents, and concurrent peer connections.

## Features

- Bencode parsing and serialization
- Torrent file parsing (single and multi-file)
- HTTP and UDP tracker support
- BitTorrent peer wire protocol
- Piece verification with SHA-1 hashing
- Concurrent downloads from multiple peers
- Thread pool for peer management
- Download progress tracking and metrics
- Automatic peer discovery and connection management

## Building

Requirements:
- Zig 0.14.0 or later

```bash
# Build
zig build

# Build and run
zig build run -- <torrent_file> [options]

# Run tests
zig build test
```

## Usage

```bash
# Basic usage
./bolt example.torrent

# Specify output directory
./bolt example.torrent --output-dir ./downloads

# Custom port and peer limit
./bolt example.torrent --port 6882 --max-peers 100

# Show help
./bolt --help
```

### Command Line Options

- `--output-dir <dir>`: Output directory for downloaded files (default: current directory)
- `--port <port>`: Listen port for incoming connections (default: 6881)
- `--max-peers <num>`: Maximum number of concurrent peer connections (default: 50)
- `--help`: Show help message

## Architecture

- **Bencode**: Parser and serializer for BitTorrent's bencode format
- **Torrent Parser**: Extracts metadata from .torrent files
- **Tracker Client**: Communicates with HTTP/UDP trackers to discover peers
- **Peer Manager**: Manages connections to multiple peers concurrently
- **Piece Manager**: Handles piece requests, verification, and assembly
- **File I/O**: Manages writing downloaded data to disk (single/multi-file support)
- **Thread Pool**: Provides concurrent execution for peer connections

## Development

### Running Tests

```bash
# Run all tests
zig build test

# Run specific test file
zig test src/bencode.zig
```

## Protocol Support

### Trackers
- HTTP/HTTPS trackers with announce URL
- UDP trackers with connection protocol
- Announce-list support for backup trackers
- Automatic fallback between tracker types

### BitTorrent Protocol
- Handshake and peer identification
- Message types: choke, unchoke, interested, have, bitfield, request, piece
- Block-based piece downloading (16KB blocks)
- SHA-1 piece verification
- Keep-alive and timeout handling

## Known Limitations

- IPv6 peer support is basic
- No DHT (Distributed Hash Table) support yet
- No peer exchange (PEX) protocol
- No encryption support
- No seeding capability (download-only)

## License

MIT License - see LICENSE file for details

## Contributing

Contributions are welcome! Please ensure:
- Code follows Zig conventions
- Tests pass (`zig build test`)
- New features include appropriate tests
- Documentation is updated as needed