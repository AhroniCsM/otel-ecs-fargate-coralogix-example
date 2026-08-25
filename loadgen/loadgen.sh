#!/bin/sh
# =============================================================================
#  loadgen — the "outpatient clinic" (מרפאת חוץ) that keeps the demo alive
# =============================================================================
#  Deliberately NOT instrumented. It plays the role of a third party outside the
#  Ministry of Health, so the FIRST span of every trace belongs to the MoH edge
#  service -- exactly like production, where the clinic is behind your ALB.
#
#  It drives the BLUE flow:
#    BLUE  : POST /api/v1/hub/messages   on edge-dotnet
# =============================================================================
set -u

EDGE_URL="${EDGE_URL:-http://localhost:8080}"
INTERVAL="${INTERVAL:-10}"          # seconds between BLUE requests

echo "loadgen: edge=$EDGE_URL interval=${INTERVAL}s"

# Wait for the edge service to come up before hammering it.
until curl -sf -o /dev/null "$EDGE_URL/healthz"; do
  echo "loadgen: waiting for edge-dotnet..."; sleep 5
done

i=0
while true; do
  i=$((i + 1))

  # The two candidate correlation GUIDs from the MoH JSON contract.
  HUB_MESSAGE_ID=$(cat /proc/sys/kernel/random/uuid)
  MESSAGE_ID=$(cat /proc/sys/kernel/random/uuid)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000+00:00)
  RESEARCH_ID=$((14000 + i % 900))

  # --- BLUE: clinic -> ALB -> API GW -> Lambda -> SQS ------------------------
  # Body shape copied from the real Ministry of Health message contract.
  BODY=$(cat <<JSON
{
  "appHeader": {
    "hl_request_number": "43424$((i % 10))",
    "research_id": $RESEARCH_ID,
    "hub_message_id": "$HUB_MESSAGE_ID",
    "timestamp": "$NOW",
    "message_id": "$MESSAGE_ID",
    "tamar_id": "MOH_2024_000239",
    "medical_institution_id": "01201",
    "service_id": "22"
  },
  "data": {
    "status": 200,
    "message_data": {
      "hl_request_number": "43424$((i % 10))",
      "research_id": $RESEARCH_ID,
      "error_id": 0,
      "message": "Update request approved",
      "is_approved": 1,
      "files": []
    }
  }
}
JSON
)

  # The GUID travels in BOTH the query string and a header. The query string is
  # what the OTel collector parses into the `hub.message_id` span attribute -
  # see infra/otel-collector/otel-config.yaml.
  curl -sf -o /dev/null -X POST \
    -H 'Content-Type: application/json' \
    -H "x-hub-message-id: $HUB_MESSAGE_ID" \
    --data "$BODY" \
    "$EDGE_URL/api/v1/hub/messages?hub_message_id=$HUB_MESSAGE_ID" \
    && echo "BLUE  sent hub_message_id=$HUB_MESSAGE_ID" \
    || echo "BLUE  FAILED hub_message_id=$HUB_MESSAGE_ID"

  sleep "$INTERVAL"
done
