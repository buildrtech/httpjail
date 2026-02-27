# httpjail

[![Documentation](https://img.shields.io/badge/docs-coder.github.io%2Fhttpjail-blue?logo=readthedocs&style=flat-square)](https://coder.github.io/httpjail/)
[![Crates.io](https://img.shields.io/crates/v/httpjail.svg)](https://crates.io/crates/httpjail)
[![CI](https://github.com/coder/httpjail/actions/workflows/tests.yml/badge.svg)](https://github.com/coder/httpjail/actions/workflows/tests.yml)

A cross-platform tool for monitoring and restricting HTTP/HTTPS requests from processes using network isolation and transparent proxy interception.

Install:

```bash
cargo install httpjail
```

Or download a pre-built binary from the [releases page](https://github.com/coder/httpjail/releases).

## Features

> [!WARNING]
> httpjail is experimental and offers no API or CLI compatibility guarantees.

- 🔒 **Process-level network isolation** - Isolate processes in restricted network environments
- 🌐 **HTTP/HTTPS interception** - Transparent proxy with TLS certificate injection
- 🛡️ **DNS exfiltration protection** - Prevents data leakage through DNS queries
- 🔧 **Multiple evaluation approaches** - JS expressions or custom programs
- 🖥️ **Cross-platform** - Native support for Linux and macOS

## Quick Start

> By default, httpjail denies all network requests. Provide a JS rule or script to allow traffic.

```bash
# Allow only requests to github.com (JS)
httpjail --js "r.host === 'github.com'" -- your-app

# Load JS from a file (auto-reloads on file changes)
echo "/^api\\.example\\.com$/.test(r.host) && r.method === 'GET'" > rules.js
httpjail --js-file rules.js -- curl https://api.example.com/health
# File changes are detected and reloaded automatically on each request

# Log requests to a file
httpjail --request-log requests.log --js "true" -- npm install
# Log format: "<timestamp> <+/-> <METHOD> <URL>" (+ = allowed, - = blocked)

# Use shell script for request evaluation (process per request)
httpjail --sh "/path/to/script.sh" -- ./my-app
# Script receives env vars: HTTPJAIL_URL, HTTPJAIL_METHOD, HTTPJAIL_HOST, etc.
# Exit code 0 allows, non-zero blocks

# Use line processor for request evaluation (efficient persistent process)
httpjail --proc /path/to/filter.py -- ./my-app
# Program receives JSON on stdin (one per line) and outputs allow/deny decisions
# stdin  -> {"method": "GET", "url": "https://api.github.com", "host": "api.github.com", "headers": {...}, ...}
# stdout -> true

# Rewrite/add request headers when a request is allowed
httpjail --js "({allow: true, set_headers: {'x-httpjail-scope': 'sandbox'}})" -- curl https://api.github.com

# Run as standalone proxy server (no command execution) and allow all
httpjail --server --js "true"
# Server defaults to ports 8080 (HTTP) and 8443 (HTTPS)
# Configure your application:
# HTTP_PROXY=http://localhost:8080 HTTPS_PROXY=http://localhost:8443

# Run Docker containers with network isolation (Linux only)
httpjail --js "r.host === 'api.github.com'" --docker-run -- --rm alpine:latest wget -qO- https://api.github.com

# Add raw TCP passthrough ports for Docker mode (comma-separated)
HTTPJAIL_DOCKER_EXTRA_TCP_PORTS=5432,5439 httpjail --js "true" --docker-run -- --rm postgres:17 psql -h 10.0.10.112 -p 5432 -U user db
HTTPJAIL_DOCKER_EXTRA_TCP_PORTS=5432,5439 httpjail --js "true" --docker-run -- --rm postgres:17 psql -h redshift-cluster.example.us-east-1.redshift.amazonaws.com -p 5439 -U user db
HTTPJAIL_DOCKER_EXTRA_TCP_PORTS=8787 httpjail --js "true" --docker-run -- --rm alpine:latest wget -qO- -T 3 http://host.docker.internal:8787/health
```

## Documentation

Docs are stored in the `docs/` directory and served
at [coder.github.io/httpjail](https://coder.github.io/httpjail).

Table of Contents:

- [Installation](https://coder.github.io/httpjail/guide/installation.html)
- [Quick Start](https://coder.github.io/httpjail/guide/quick-start.html)
- [Configuration](https://coder.github.io/httpjail/guide/configuration.html)
- [Rule Engines](https://coder.github.io/httpjail/guide/rule-engines/index.html)
  - [JavaScript](https://coder.github.io/httpjail/guide/rule-engines/javascript.html)
  - [Shell](https://coder.github.io/httpjail/guide/rule-engines/shell.html)
  - [Line Processor](https://coder.github.io/httpjail/guide/rule-engines/line-processor.html)
- [Platform Support](https://coder.github.io/httpjail/guide/platform-support.html)
- [Request Logging](https://coder.github.io/httpjail/guide/request-logging.html)
- [TLS Interception](https://coder.github.io/httpjail/advanced/tls-interception.html)
- [DNS Exfiltration](https://coder.github.io/httpjail/advanced/dns-exfiltration.html)
- [Server Mode](https://coder.github.io/httpjail/advanced/server-mode.html)

## License

This project is released into the public domain under the CC0 1.0 Universal license. See [LICENSE](LICENSE) for details.
