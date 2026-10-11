# Reqly for Linux (C++ Native)

A native, high-performance Linux port of Reqly written in C++20 with GTK3, OpenSSL, and Ninja.

## Features

- **Dual-Mode Launcher**:
  - **Desktop Application Menu**: Clicking **Reqly** in the application menu launches the full Desktop GUI directly.
  - **Terminal / CLI**: Running `reqly` in a terminal prompts the user to select between **GUI** and **CLI** modes, or accepts `--gui` (`-g`) and `--cli` (`-c`) flags.
- **Engine Capabilities**:
  - HTTP and HTTPS proxy on `127.0.0.1:9090` (customizable via `--port`).
  - Dynamic on-the-fly SSL/TLS Certificate Authority using OpenSSL with Subject Alternative Names (SAN).
  - Rules engine supporting Breakpoints, Map Local, Map Remote, Header/Body Rewrites, Block, and 3G Latency Throttling.
  - In-memory structured traffic storage with search, method, and status filtering.
  - Export captured sessions to standard HTTP Archive (HAR 1.2) files.
  - Linux process resolver mapping connection ports to local process PIDs and executable names via `/proc/net/tcp` and `/proc/<pid>/exe`.
  - Automatic Linux system proxy configuration (GNOME `gsettings`) with safe restoration on exit.

## Building and Packaging

Compile and build the `.deb` package:

```bash
# Using the automated packaging script
./linux-dists/packaging/build_deb.sh
```

Or build manually with CMake and Ninja:

```bash
cmake -B linux-dists/build -S linux-dists -G Ninja
ninja -C linux-dists/build -j$(nproc)
```

## Installing the Debian Package

The built `.deb` package is placed directly in the repository root:

```bash
sudo dpkg -i reqly_1.0.0_amd64.deb
```
