#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-ca-central-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-449678530532}"
ECR_REPOSITORY="${ECR_REPOSITORY:-idblu-tts}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-docker/Dockerfile.idblu_tts}"
PLATFORM="${PLATFORM:-linux/amd64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TAG=""
PUSH_LATEST=false
YES=false
INTERACTIVE=false

if [[ $# -eq 0 ]]; then
  INTERACTIVE=true
fi

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build-push-ecr.sh
  ./scripts/build-push-ecr.sh [--tag TAG] [--latest] [--yes]

Builds and pushes the ID-BLU TTS wrapper image to ECR.

Defaults:
  tag         0.1.0-<short-git-sha>
  repository 449678530532.dkr.ecr.ca-central-1.amazonaws.com/idblu-tts
  platform   linux/amd64

Options:
  --tag TAG   Use an explicit image tag.
  --latest    Also push idblu-tts:latest.
  --yes       Skip interactive confirmations.

Without options, the script opens an interactive menu.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --latest)
      PUSH_LATEST=true
      shift
      ;;
    --yes|-y)
      YES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

confirm() {
  [ "$YES" = true ] && return 0
  echo "ID-BLU TTS image build plan:"
  echo "  Repository: ${ECR_REGISTRY}/${ECR_REPOSITORY}"
  echo "  Tag:        ${TAG}"
  echo "  Dockerfile: ${DOCKERFILE_PATH}"
  echo "  Platform:   ${PLATFORM}"
  echo "  Push latest: ${PUSH_LATEST}"
  read -r -p "Continue? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
}

interactive_menu() {
  local default_tag="$1"
  local choice custom_tag latest_answer

  echo "================================================"
  echo "   ID-BLU TTS - Build and Push"
  echo "================================================"
  echo ""
  echo "Branch: ${BRANCH}"
  echo "Commit: ${FULL_SHA}"
  echo ""
  echo "Select image tag:"
  echo "  1) Default dev tag (${default_tag})"
  echo "  2) Custom tag"
  echo ""

  while true; do
    read -r -p "Select [1-2]: " choice
    case "$choice" in
      1)
        TAG="$default_tag"
        break
        ;;
      2)
        read -r -p "Custom tag: " custom_tag
        if [[ -n "$custom_tag" ]]; then
          TAG="$custom_tag"
          break
        fi
        echo "Tag cannot be empty."
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done

  read -r -p "Also push idblu-tts:latest? [y/N] " latest_answer
  case "$latest_answer" in
    y|Y|yes|YES) PUSH_LATEST=true ;;
    *) PUSH_LATEST=false ;;
  esac
}

require_tool aws
require_tool docker
require_tool git

cd "$PROJECT_DIR"

if ! docker buildx version >/dev/null 2>&1; then
  echo "Docker buildx is required but is not available." >&2
  exit 1
fi

if [[ ! -f "$DOCKERFILE_PATH" ]]; then
  echo "Dockerfile not found: $DOCKERFILE_PATH" >&2
  exit 1
fi

SHORT_SHA="$(git rev-parse --short HEAD)"
FULL_SHA="$(git rev-parse HEAD)"
BRANCH="$(git branch --show-current)"
DEFAULT_TAG="0.1.0-${SHORT_SHA}"

if [[ "$INTERACTIVE" == true ]]; then
  interactive_menu "$DEFAULT_TAG"
elif [[ -z "$TAG" ]]; then
  TAG="$DEFAULT_TAG"
fi

if [[ "$TAG" == "latest" ]]; then
  echo "Refusing to use 'latest' as the primary deployment tag." >&2
  exit 1
fi

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  echo "Warning: repo has uncommitted changes:"
  git status --short
  if [[ "$YES" != true ]]; then
    read -r -p "Build with uncommitted changes? [y/N] " dirty_answer
    case "$dirty_answer" in
      y|Y|yes|YES) ;;
      *) echo "Cancelled."; exit 0 ;;
    esac
  fi
fi

ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:${TAG}"
LATEST_IMAGE="${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"

confirm

echo "Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null

echo "Ensuring ECR repository exists..."
if ! aws ecr describe-repositories \
  --repository-names "$ECR_REPOSITORY" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ecr create-repository \
    --repository-name "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 >/dev/null
fi

build_args=(
  buildx build
  --platform "$PLATFORM"
  -f "$DOCKERFILE_PATH"
  --build-arg "FORK_COMMIT=${FULL_SHA}"
  --build-arg "WRAPPER_VERSION=${TAG}"
  -t "$IMAGE"
)

if [[ "$PUSH_LATEST" == true ]]; then
  build_args+=(-t "$LATEST_IMAGE")
fi

build_args+=(--push .)

echo "Building and pushing ${IMAGE}..."
docker "${build_args[@]}"

echo ""
echo "Image pushed: ${IMAGE}"
if [[ "$PUSH_LATEST" == true ]]; then
  echo "Latest pushed: ${LATEST_IMAGE}"
fi
echo "Branch: ${BRANCH}"
echo "Commit: ${FULL_SHA}"
