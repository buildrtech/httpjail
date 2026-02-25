#!/usr/bin/env bash
set -euo pipefail

# Build httpjail for Linux and upload the binary to S3.
#
# Examples:
#   ./scripts/build-and-upload-s3.sh
#   ./scripts/build-and-upload-s3.sh --target x86_64-unknown-linux-gnu
#   ./scripts/build-and-upload-s3.sh --bucket buildr-oss-binaries --key httpjail/httpjail-linux-aarch64
#   ./scripts/build-and-upload-s3.sh --native-build

DEFAULT_PROFILE="buildr-oss-binaries"
DEFAULT_REGION="us-east-1"
DEFAULT_BUCKET="buildr-oss-binaries"
DEFAULT_PREFIX="httpjail"
DEFAULT_DOCKER_IMAGE="rust:bookworm"

PROFILE="$DEFAULT_PROFILE"
REGION="$DEFAULT_REGION"
BUCKET="$DEFAULT_BUCKET"
KEY=""
TARGET=""
SKIP_BUILD=0
USE_DOCKER=1
DOCKER_IMAGE="$DEFAULT_DOCKER_IMAGE"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --target <triple>   Rust target (default: auto-detect from host arch)
  --bucket <name>     S3 bucket (default: $DEFAULT_BUCKET)
  --key <path>        S3 object key (default: httpjail/httpjail-linux-<arch>)
  --profile <name>    AWS profile (default: $DEFAULT_PROFILE)
  --region <name>     AWS region (default: $DEFAULT_REGION)
  --skip-build        Skip build and upload existing binary
  --native-build      Build on host instead of Docker
  --docker-image <i>  Docker builder image (default: $DEFAULT_DOCKER_IMAGE)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --bucket)
      BUCKET="$2"
      shift 2
      ;;
    --key)
      KEY="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --native-build)
      USE_DOCKER=0
      shift
      ;;
    --docker-image)
      DOCKER_IMAGE="$2"
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
  case "$(uname -m)" in
    aarch64|arm64)
      TARGET="aarch64-unknown-linux-gnu"
      ARCH_LABEL="aarch64"
      DOCKER_PLATFORM="linux/arm64"
      ;;
    x86_64|amd64)
      TARGET="x86_64-unknown-linux-gnu"
      ARCH_LABEL="amd64"
      DOCKER_PLATFORM="linux/amd64"
      ;;
    *)
      echo "Unsupported host arch: $(uname -m). Pass --target explicitly." >&2
      exit 1
      ;;
  esac
else
  case "$TARGET" in
    aarch64-unknown-linux-gnu)
      ARCH_LABEL="aarch64"
      DOCKER_PLATFORM="linux/arm64"
      ;;
    x86_64-unknown-linux-gnu)
      ARCH_LABEL="amd64"
      DOCKER_PLATFORM="linux/amd64"
      ;;
    *)
      echo "Unsupported target: $TARGET (expected aarch64-unknown-linux-gnu or x86_64-unknown-linux-gnu)" >&2
      exit 1
      ;;
  esac
fi

if [[ -z "$KEY" ]]; then
  KEY="$DEFAULT_PREFIX/httpjail-linux-$ARCH_LABEL"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

build_native() {
  echo "Building httpjail natively for $TARGET..."
  if ! rustup target list --installed | grep -q "^${TARGET}$"; then
    rustup target add "$TARGET"
  fi
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

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if [[ "$USE_DOCKER" -eq 1 ]]; then
    build_docker
  else
    build_native
  fi
fi

BINARY="target/$TARGET/release/httpjail"
if [[ ! -f "$BINARY" ]]; then
  echo "Binary not found: $BINARY" >&2
  exit 1
fi

SHA256="$(sha256sum "$BINARY" | awk '{print $1}')"

echo "Uploading $BINARY to s3://$BUCKET/$KEY ..."
aws --profile "$PROFILE" --region "$REGION" s3 cp "$BINARY" "s3://$BUCKET/$KEY"

cat <<EOF

Upload complete.

Artifact:
  s3://$BUCKET/$KEY

SHA256:
  $SHA256

Terraform local values (bizops-infra/terraform/aws/kitbot.tf):
  httpjail_binary_s3_key = "$KEY"
  httpjail_binary_sha256 = "$SHA256"
EOF
