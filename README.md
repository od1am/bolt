# Bolt

A BitTorrent client implementation written in Zig.

## Features

- Pure Zig implementation with minimal dependencies
- Support for downloading and seeding torrents
- DHT implementation for trackerless operation
- Fast piece selection and download algorithms
- IPv4 and IPv6 support

## Usage

```sh
# Download a torrent
./bolt --torrent /torrent/file/path

# Create a torrent from a file or directory
./bolt create path/to/file --output my_file.torrent

# Seed a torrent
./bolt seed path/to/file.torrent
```

## Building from Source

Requires Zig 0.13.0 or later.

```sh
zig build
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Feature Roadmap

### Core Functionality (In Progress)
- [x] Bencode decoder
- [ ] Pipelined Requests
- [ ] Concurrency
- [ ] Stable networking layer with proper connection handling
- [x] Basic peer discovery and connection management
- [ ] Reliable piece downloading and verification
- [ ] Complete DHT bootstrapping process

### Phase 1: Basic Client Stability
- [ ] Implement robust error handling throughout codebase
- [ ] Add proper logging system
- [ ] Support resume of partial downloads
- [ ] Basic rate limiting implementation
- [ ] Improve peer selection algorithm

### Phase 2: Essential Features
- [ ] Magnet link support
- [ ] Multiple simultaneous downloads
- [ ] Accurate progress reporting and statistics
- [ ] Basic configuration system
- [ ] Implement missing BitTorrent protocol extensions

### Phase 3: Advanced Features
- [ ] Web interface for management
- [ ] UPnP support for automatic port forwarding
- [ ] Bandwidth throttling and scheduling
- [ ] Metadata-only mode for fast torrent inspection
- [ ] Streaming support

## License

MIT License
