# =============================================================================
#  hub-python  —  Ministry of Health "HUB" routing service
# =============================================================================
#  WHAT THIS STANDS IN FOR IN YOUR ARCHITECTURE
#  --------------------------------------------
#   BLUE flow (clinic -> MoH):  the routing Lambda behind API Gateway.
#       POST /process   -> pushes the message onto SQS(blue)
#
#  >>> CUSTOMER: THIS FILE CONTAINS ZERO OPENTELEMETRY CODE. <<<
#  No `from opentelemetry import ...`, no tracer, no `start_span`, no decorators.
#  Every span comes from `opentelemetry-instrument` (see Dockerfile), which
#  auto-instruments FastAPI (server spans) and botocore (SQS spans), and
#  injects `traceparent` into outgoing calls for you.
# =============================================================================

import json
import logging
import os
import uuid

import boto3
from fastapi import FastAPI, Request

# ---------------------------------------------------------------------------
# CUSTOMER: EDIT HERE. These are the only integration points with your infra.
# ---------------------------------------------------------------------------
AWS_REGION     = os.environ.get("AWS_REGION", "eu-north-1")
BLUE_QUEUE_URL = os.environ["BLUE_QUEUE_URL"]     # SQS queue for the BLUE flow

# GOTCHA WORTH KNOWING: under `opentelemetry-instrument` the OTLP LoggingHandler
# is already attached to the root logger before your code runs, so
# logging.basicConfig() silently does NOTHING (it bails out when the root logger
# already has handlers) and the root level stays at WARNING -- meaning none of
# your INFO logs ever reach Coralogix. Set the level explicitly.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger("hub-python")
log.setLevel(logging.INFO)

app = FastAPI()

# botocore is auto-instrumented the moment it is imported under
# `opentelemetry-instrument` -> every SQS call becomes a span.
sqs = boto3.client("sqs", region_name=AWS_REGION)


# =============================================================================
#  BLUE FLOW  —  step 2 of 2
#  edge-dotnet --HTTP--> [routing Lambda : this endpoint] --SQS--> (blue queue)
# =============================================================================
@app.post("/process")
async def process(request: Request):
    hub_message_id = (
        request.query_params.get("hub_message_id")
        or request.headers.get("x-hub-message-id")
        or str(uuid.uuid4())
    )
    try:
        payload = await request.json()
    except Exception:
        payload = {}

    app_header = payload.get("appHeader", {})
    # The two candidate correlation fields from the MoH JSON contract.
    # `hub_message_id` is the one we treat as the join key here.
    message_id = app_header.get("message_id") or str(uuid.uuid4())

    log.info(
        "BLUE 2/2 routing to SQS hub_message_id=%s message_id=%s research_id=%s",
        hub_message_id, message_id, app_header.get("research_id"),
    )

    body = {
        "appHeader": {
            **app_header,
            "hub_message_id": hub_message_id,
            "message_id": message_id,
        },
        "data": payload.get("data", {}),
    }

    # botocore auto-instrumentation creates the SQS producer span here.
    # We also put the GUID in a MessageAttribute so that (a) the consumer can
    # read it without parsing the body and (b) it shows up on the span.
    sqs.send_message(
        QueueUrl=BLUE_QUEUE_URL,
        MessageBody=json.dumps(body),
        MessageAttributes={
            "hub_message_id": {"DataType": "String", "StringValue": hub_message_id},
            "message_id": {"DataType": "String", "StringValue": message_id},
        },
    )

    return {"routed": True, "hub_message_id": hub_message_id, "message_id": message_id}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
