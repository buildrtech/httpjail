#!/usr/bin/env bash
set -euo pipefail

# Build httpjail for Linux and upload the binaries to S3.
#
# Examples:
#   ./scripts/build-and-upload-s3.sh
#   ./scripts/build-and-upload-s3.sh --target x86_64-unknown-linux-gnu
#   ./scripts/build-and-upload-s3.sh --bucket buildr-oss-binaries --key httpjail/httpjail-linux
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
TARGETS=()
SKIP_BUILD=0
USE_DOCKER=1
DOCKER_IMAGE="$DEFAULT_DOCKER_IMAGE"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --target <triple>   Rust target (default: build both aarch64 and x86_64)
                      Can be provided multiple times.
  --bucket <name>     S3 bucket (default: $DEFAULT_BUCKET)
  --key <path>        Base S3 object key.
                      If building multiple targets, -<arch>-<git short sha> is appended.
                      If building one target, -<git short sha> is appended.
  --profile <name>    AWS profile (default: $DEFAULT_PROFILE)
  --region <name>     AWS region (default: $DEFAULT_REGION)
  --skip-build        Skip build and upload existing binaries
  --native-build      Build on host instead of Docker
  --docker-image <i>  Docker builder image (default: $DEFAULT_DOCKER_IMAGE)
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGETS+=("$2")
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

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(
    "aarch64-unknown-linux-gnu"
    "x86_64-unknown-linux-gnu"
  )
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SHORT_SHA="$(git rev-parse --short HEAD)"
MULTI_TARGET=0
if [[ ${#TARGETS[@]} -gt 1 ]]; then
  MULTI_TARGET=1
fi

for TARGET in "${TARGETS[@]}"; do
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

  if [[ -z "$KEY" ]]; then
    BASE_KEY="$DEFAULT_PREFIX/httpjail-linux-$ARCH_LABEL"
  elif [[ "$MULTI_TARGET" -eq 1 ]]; then
    BASE_KEY="$KEY-$ARCH_LABEL"
  else
    BASE_KEY="$KEY"
  fi

  VERSIONED_KEY="$BASE_KEY-$SHORT_SHA"

  if [[ "$SKIP_BUILD" -eq 0 ]]; then
    BUILD_SCRIPT=(
      "$REPO_ROOT/scripts/build-linux-binary.sh"
      --target "$TARGET"
      --docker-image "$DOCKER_IMAGE"
      --docker-platform "$DOCKER_PLATFORM"
    )

    if [[ "$USE_DOCKER" -eq 0 ]]; then
      BUILD_SCRIPT+=(--native-build)
    fi

    "${BUILD_SCRIPT[@]}"
  fi

  BINARY="target/$TARGET/release/httpjail"
  if [[ ! -f "$BINARY" ]]; then
    echo "Binary not found: $BINARY" >&2
    exit 1
  fi

  SHA256="$(sha256sum "$BINARY" | awk '{print $1}')"

  echo "Uploading $BINARY to s3://$BUCKET/$VERSIONED_KEY ..."
  aws --profile "$PROFILE" --region "$REGION" s3 cp "$BINARY" "s3://$BUCKET/$VERSIONED_KEY"

  cat <<EOF

Upload complete for $TARGET.

Artifact:
  s3://$BUCKET/$VERSIONED_KEY

Git commit short SHA:
  $SHORT_SHA

SHA256:
  $SHA256

Terraform local values (bizops-infra/terraform/aws/kitbot.tf):
  httpjail_binary_s3_key = "$VERSIONED_KEY"
  httpjail_binary_sha256 = "$SHA256"
EOF
done
