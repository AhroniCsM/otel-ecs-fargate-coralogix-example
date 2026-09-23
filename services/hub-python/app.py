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
import psycopg                       # v3; auto-instrumented -> DB CLIENT spans
from fastapi import FastAPI, Request

# ---------------------------------------------------------------------------
# CUSTOMER: EDIT HERE. These are the only integration points with your infra.
# ---------------------------------------------------------------------------
AWS_REGION     = os.environ.get("AWS_REGION", "eu-north-1")
BLUE_QUEUE_URL = os.environ["BLUE_QUEUE_URL"]     # SQS queue for the BLUE flow

# Postgres audit trail — this is what lights up the Coralogix DATABASE CATALOG.
# psycopg (v3) is auto-instrumented by `opentelemetry-instrument`, so every INSERT/
# SELECT below becomes a DB CLIENT span (db.system=postgresql, db.name,
# db.statement) with zero OpenTelemetry code. Unset PG_HOST to disable.
PG_HOST     = os.environ.get("PG_HOST")           # e.g. "postgres" (Service Connect)
PG_USER     = os.environ.get("PG_USER", "moh")
PG_PASSWORD = os.environ.get("PG_PASSWORD", "")
PG_DB       = os.environ.get("PG_DB", "mohhub")
_pg_ready   = False


def _pg_conn():
    return psycopg.connect(host=PG_HOST, port=5432, user=PG_USER,
                           password=PG_PASSWORD, dbname=PG_DB, connect_timeout=3)


def _audit_message(hub_message_id: str, message_id: str) -> int:
    """INSERT the routed message + SELECT the running total.

    Two real queries per transaction so the Database Catalog shows both an
    INSERT and a SELECT operation. Table creation is lazy so the demo never
    needs a migration step.
    """
    global _pg_ready
    conn = _pg_conn()
    try:
        with conn, conn.cursor() as cur:
            if not _pg_ready:
                cur.execute("""CREATE TABLE IF NOT EXISTS hub_messages (
                                 id SERIAL PRIMARY KEY,
                                 hub_message_id UUID NOT NULL,
                                 message_id UUID NOT NULL,
                                 routed_at TIMESTAMPTZ NOT NULL DEFAULT now())""")
                _pg_ready = True
            cur.execute(
                "INSERT INTO hub_messages (hub_message_id, message_id) VALUES (%s, %s)",
                (hub_message_id, message_id),
            )
            cur.execute("SELECT count(*) FROM hub_messages")
            return cur.fetchone()[0]
    finally:
        conn.close()

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

    # Postgres audit trail (Database Catalog). Failure is logged, never fatal —
    # the demo keeps routing even if the DB is down or PG_HOST is unset.
    if PG_HOST:
        try:
            total = _audit_message(hub_message_id, message_id)
            log.info("BLUE 2/2 audited to postgres hub_message_id=%s total_rows=%s",
                     hub_message_id, total)
        except Exception as exc:  # noqa: BLE001 - demo resilience
            log.warning("postgres audit failed hub_message_id=%s err=%s",
                        hub_message_id, exc)

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
