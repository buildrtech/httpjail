#!/usr/bin/env bash
set -euo pipefail

# Build httpjail for Linux.
#
# Examples:
#   ./scripts/build-linux-binary.sh --target x86_64-unknown-linux-gnu
#   ./scripts/build-linux-binary.sh --target aarch64-unknown-linux-gnu --native-build
#   ./scripts/build-linux-binary.sh --target x86_64-unknown-linux-gnu --docker-image rust:bookworm

DEFAULT_DOCKER_IMAGE="rust:bookworm"

TARGET=""
USE_DOCKER=1
DOCKER_IMAGE="$DEFAULT_DOCKER_IMAGE"
DOCKER_PLATFORM=""

usage() {
  cat <<EOF
Usage: $0 --target <triple> [options]

Options:
  --target <triple>   Rust target (required)
  --native-build      Build on host instead of Docker
  --docker-image <i>  Docker builder image (default: $DEFAULT_DOCKER_IMAGE)
  --docker-platform <p> Docker platform (default: inferred from target)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --native-build)
      USE_DOCKER=0
      shift
      ;;
    --docker-image)
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    --docker-platform)
      DOCKER_PLATFORM="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "--target is required" >&2
  usage
  exit 1
fi

case "$TARGET" in
  aarch64-unknown-linux-gnu)
    if [[ -z "$DOCKER_PLATFORM" ]]; then
      DOCKER_PLATFORM="linux/arm64"
    fi
    ;;
  x86_64-unknown-linux-gnu)
    if [[ -z "$DOCKER_PLATFORM" ]]; then
      DOCKER_PLATFORM="linux/amd64"
    fi
    ;;
  *)
    echo "Unsupported target: $TARGET (expected aarch64-unknown-linux-gnu or x86_64-unknown-linux-gnu)" >&2
    exit 1
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

build_native() {
  echo "Building httpjail natively for $TARGET..."
  rustup target add "$TARGET" >/dev/null 2>&1 || true
  RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --target "$TARGET"
}

build_docker() {
  echo "Building httpjail in Docker ($DOCKER_IMAGE) for $TARGET..."
  docker run --rm \
    --platform "$DOCKER_PLATFORM" \
    -e TARGET="$TARGET" \
    -v "$REPO_ROOT":/work \
    -w /work \
    "$DOCKER_IMAGE" \
    bash -lc '
      set -euo pipefail
      export PATH=/usr/local/cargo/bin:$PATH
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends pkg-config cmake clang make gcc g++ perl >/dev/null
      rustup target add "$TARGET" >/dev/null 2>&1 || true
      RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --target "$TARGET"
    '
}

if [[ "$USE_DOCKER" -eq 1 ]]; then
  build_docker
else
  build_native
fi

BINARY="target/$TARGET/release/httpjail"
if [[ ! -f "$BINARY" ]]; then
  echo "Binary not found: $BINARY" >&2
  exit 1
fi

echo "Build complete: $BINARY"
