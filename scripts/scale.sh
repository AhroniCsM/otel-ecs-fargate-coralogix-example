#!/usr/bin/env bash
# =============================================================================
#  Stop / start the lab without destroying anything.
#
#    ./scripts/scale.sh stop     -> all tasks stopped, cost ~= $0
#    ./scripts/scale.sh start    -> tasks back, traffic resumes in ~1 min
#    ./scripts/scale.sh status
#
#  "stop" just scales every service's desired count to 0, which stops
#  billing for that service's tasks immediately. What is left behind
#  costs approximately nothing: SQS queues,
#  ECR images with a keep-last-3 lifecycle, IAM roles, and a 3-day CloudWatch
#  log group.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
PROJECT="${PROJECT_NAME:-moh-hub-otel}"
APP_SERVICES=(otel-collector edge-dotnet hub-python loadgen)

case "${1:-status}" in
  stop)
    for s in "${APP_SERVICES[@]}"; do
      aws ecs update-service --region "$REGION" --cluster "$PROJECT" \
        --service "$s" --desired-count 0 --query 'service.serviceName' --output text
    done
    echo "==> stopped."
    ;;
  start)
    for s in "${APP_SERVICES[@]}"; do
      aws ecs update-service --region "$REGION" --cluster "$PROJECT" \
        --service "$s" --desired-count 1 --query 'service.serviceName' --output text
    done
    echo "==> started. Traffic resumes shortly; spans are queryable ~2-4 min later."
    ;;
  status)
    aws ecs describe-services --region "$REGION" --cluster "$PROJECT" \
      --services "${APP_SERVICES[@]}" \
      --query 'services[].{service:serviceName,desired:desiredCount,running:runningCount}' --output table
    ;;
  *) echo "usage: $0 {stop|start|status}"; exit 1 ;;
esac
