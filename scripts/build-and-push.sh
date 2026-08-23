#!/usr/bin/env bash
# =============================================================================
#  Build all five images for the ECS instance architecture and push to ECR.
# =============================================================================
#  CUSTOMER: ARCH must match the EC2 instance family in 02-ecs.yaml.
#    t4g.*  (Graviton, cheapest) -> linux/arm64
#    t3.*   (Intel)              -> linux/amd64
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
PROJECT="${PROJECT_NAME:-moh-hub-otel}"
ARCH="${ARCH:-linux/arm64}"
TAG="${IMAGE_TAG:-latest}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">> logging in to ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

build_push () {                      # $1 = image name, $2 = build context
  local name="$1" ctx="$2"
  local uri="${REGISTRY}/${PROJECT}/${name}:${TAG}"
  echo ">> building ${name} for ${ARCH}"
  docker build --platform "$ARCH" -t "$uri" "$ctx"
  echo ">> pushing ${name}"
  docker push -q "$uri"
}

build_push otel-collector "$ROOT/infra/otel-collector"
build_push edge-dotnet    "$ROOT/services/edge-dotnet"
build_push hub-python     "$ROOT/services/hub-python"
build_push worker-node    "$ROOT/services/worker-node"
build_push loadgen        "$ROOT/loadgen"

echo ">> done. all images pushed with tag '${TAG}'."
