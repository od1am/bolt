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
./bolt -t /torrent/file/path -o /download/directory
```

## Building from Source

Requires Zig version 0.13.0 or later.

```sh
zig build
```

```sh
nix run . -- -t /path/to/file.torrent -o downloads
```
## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Feature Roadmap

### Core Functionality (In Progress)
- [x] Bencode decoder
- [ ] Concurrency
- [ ] Stable networking layer with proper connection handling
- [x] Basic peer discovery and connection management
- [x] Reliable piece downloading and verification
- [ ] Complete DHT bootstrapping process

### Phase 1: Basic Client Stability
- [ ] Implement robust error handling throughout codebase
- [ ] Add proper logging system
- [ ] Non-sequential downloads
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
