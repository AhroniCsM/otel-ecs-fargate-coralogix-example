#!/usr/bin/env bash
# Tear everything down so the POC stops costing money.
set -euo pipefail
REGION="${AWS_REGION:-eu-north-1}"
PROJECT="${PROJECT_NAME:-moh-hub-otel}"

echo "==> deleting compute stack (EC2 instance, ECS services)"
aws cloudformation delete-stack --region "$REGION" --stack-name "${PROJECT}-ecs"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${PROJECT}-ecs"

echo "==> deleting foundation stack (SQS, ECR, IAM, logs)"
aws cloudformation delete-stack --region "$REGION" --stack-name "${PROJECT}-foundation"
aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "${PROJECT}-foundation"

echo "==> deleting the Coralogix key from SSM"
aws ssm delete-parameter --region "$REGION" --name "/${PROJECT}/coralogix-private-key" || true

echo "All gone."
