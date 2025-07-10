# Bolt

A BitTorrent client implementation  written in Zig.

## Building

Requirements:
- Zig 0.14.0 or later

```bash
# Build
zig build
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

### Running Tests

```bash
# Run all tests
zig build test

# Run specific test file
zig test src/bencode.zig
```

## Limitations

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

## References
- https://wiki.theory.org/BitTorrentSpecification
- https://bittorrent.org/beps/bep_0000.html
