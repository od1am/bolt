# Bolt

A BitTorrent client implementation written in Zig.

## Features

- Pure Zig implementation with minimal dependencies
- Support for downloading and seeding torrents
- DHT implementation for trackerless operation
- Fast piece selection and download algorithms
- IPv4 and IPv6 support

## Installation

```bash
git clone 
cd bolt
zig build
```

## Usage

```bash
# Download a torrent
./bolt --torrent 

# Create a torrent from a file or directory
./bolt create path/to/file --output my_file.torrent

# Seed a torrent
./bolt seed path/to/file.torrent
```

## Building from Source

Requires Zig 0.11.0 or later.

```bash
zig build
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License
