#!/usr/bin/env bash
# =============================================================================
#  Stop / start the lab without destroying anything.
#
#    ./scripts/scale.sh stop     -> EC2 instance terminated, cost ~= $0
#    ./scripts/scale.sh start    -> instance back, traffic resumes in ~2 min
#    ./scripts/scale.sh status
#
#  "stop" scales the Auto Scaling group to 0. That is what actually saves money
#  (the EC2 instance is the only meaningful cost); it also stops every task,
#  including the DAEMON collector, whose count you cannot set directly.
#  What is left behind costs approximately nothing: SQS queues, ECR images with
#  a keep-last-3 lifecycle, IAM roles, and a 3-day CloudWatch log group.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
PROJECT="${PROJECT_NAME:-moh-hub-otel}"
ASG="${PROJECT}-asg"
APP_SERVICES=(postgres edge-dotnet hub-python worker-node loadgen)

case "${1:-status}" in
  stop)
    echo "==> scaling ${ASG} to 0"
    aws autoscaling update-auto-scaling-group --region "$REGION" \
      --auto-scaling-group-name "$ASG" --min-size 0 --desired-capacity 0
    for s in "${APP_SERVICES[@]}"; do
      aws ecs update-service --region "$REGION" --cluster "$PROJECT" \
        --service "$s" --desired-count 0 --query 'service.serviceName' --output text
    done
    echo "==> stopped."
    ;;
  start)
    echo "==> scaling ${ASG} to 1"
    aws autoscaling update-auto-scaling-group --region "$REGION" \
      --auto-scaling-group-name "$ASG" --min-size 1 --desired-capacity 1
    echo "==> waiting for the instance to register with ECS"
    until [ "$(aws ecs list-container-instances --region "$REGION" --cluster "$PROJECT" \
                --query 'length(containerInstanceArns)' --output text)" != "0" ]; do sleep 10; done
    for s in "${APP_SERVICES[@]}"; do
      aws ecs update-service --region "$REGION" --cluster "$PROJECT" \
        --service "$s" --desired-count 1 --query 'service.serviceName' --output text
    done
    echo "==> started. Traffic resumes shortly; spans are queryable ~2-4 min later."
    ;;
  status)
    aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$ASG" \
      --query 'AutoScalingGroups[0].{min:MinSize,desired:DesiredCapacity,instances:length(Instances)}' --output table
    aws ecs describe-services --region "$REGION" --cluster "$PROJECT" \
      --services otel-collector "${APP_SERVICES[@]}" \
      --query 'services[].{service:serviceName,desired:desiredCount,running:runningCount}' --output table
    ;;
  *) echo "usage: $0 {stop|start|status}"; exit 1 ;;
esac
