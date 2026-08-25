#!/usr/bin/env bash
# =============================================================================
#  One-command deploy. Run from the repo root.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
PROJECT="${PROJECT_NAME:-moh-hub-otel}"
CORALOGIX_DOMAIN="${CORALOGIX_DOMAIN:-eu2.coralogix.com}"
DEPLOY_ENV="${DEPLOY_ENV:-ecs-stg-exmaple}"   # -> deployment.environment.name
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${CORALOGIX_PRIVATE_KEY:?export CORALOGIX_PRIVATE_KEY=cxtp_... (Send-Your-Data key) first}"

echo "==> 0/4  storing the Coralogix key in SSM Parameter Store (SecureString)"
# The key lives here and nowhere else - not in git, not in the templates, not
# in the task definitions. ECS injects it at container start.
aws ssm put-parameter --region "$REGION" \
  --name "/${PROJECT}/coralogix-private-key" \
  --type SecureString --overwrite \
  --value "$CORALOGIX_PRIVATE_KEY" >/dev/null

echo "==> 1/4  foundation stack (SQS, ECR, IAM, logs)"
aws cloudformation deploy --region "$REGION" \
  --template-file "$ROOT/infra/cloudformation/01-foundation.yaml" \
  --stack-name "${PROJECT}-foundation" \
  --parameter-overrides "ProjectName=${PROJECT}" \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset

echo "==> 2/4  building and pushing images"
AWS_REGION="$REGION" PROJECT_NAME="$PROJECT" "$ROOT/scripts/build-and-push.sh"

echo "==> 3/4  resolving VPC / subnet (default VPC)"
VPC=$(aws ec2 describe-vpcs --region "$REGION" \
        --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true" \
        --query 'Subnets[0].SubnetId' --output text)
echo "    VpcId=$VPC SubnetId=$SUBNET"

echo "==> 4/4  compute stack (ECS Fargate cluster, 4 services)"
aws cloudformation deploy --region "$REGION" \
  --template-file "$ROOT/infra/cloudformation/02-ecs.yaml" \
  --stack-name "${PROJECT}-ecs" \
  --parameter-overrides \
      "ProjectName=${PROJECT}" "VpcId=${VPC}" "SubnetId=${SUBNET}" \
      "CoralogixDomain=${CORALOGIX_DOMAIN}" \
      "DeploymentEnvironmentName=${DEPLOY_ENV}" \
      "CoralogixKeyParameter=/${PROJECT}/coralogix-private-key" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset

cat <<'MSG'

Done. Traffic starts immediately and never stops.
Allow ~3 minutes for the first spans to be queryable, then run:

    ./scripts/verify-traces.sh

MSG
