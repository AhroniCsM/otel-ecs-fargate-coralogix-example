// =============================================================================
//  worker-node  —  the SQS-driven "Lambdas" of the MoH HUB
// =============================================================================
//  WHAT THIS STANDS IN FOR IN YOUR ARCHITECTURE
//  --------------------------------------------
//   BLUE  step 3+4 of 5 : SQS(blue)  --> Lambda --> RDS insert
//   GREEN step 1+2 of 5 : "RDS row ready" --> Lambda --> SQS(green)
//   GREEN step 3+4 of 5 : SQS(green) --> Lambda --> F5 API GW (HTTP)
//
//  >>> CUSTOMER: THIS FILE CONTAINS ZERO OPENTELEMETRY CODE. <<<
//  No require('@opentelemetry/...'), no tracer, no startSpan, no context
//  juggling. Everything comes from
//      NODE_OPTIONS=--require @opentelemetry/auto-instrumentations-node/register
//  (see Dockerfile).
//
//  WHY BOTH SIDES OF THE GREEN QUEUE LIVE HERE
//  -------------------------------------------
//  They are two logically separate Lambdas, but both are Node, and Node's
//  @opentelemetry/instrumentation-aws-sdk is the one auto-instrumentation that
//  BOTH injects the W3C `traceparent` into SQS MessageAttributes on send AND
//  extracts it again on receive. That makes the whole GREEN flow ONE trace,
//  straight through the queue, with no code from you.
//
//  The BLUE flow deliberately has a Python producer, which does NOT inject
//  context (see README "Async & SQS"). That is why the BLUE flow arrives in
//  Coralogix as TWO traces -- and why the `hub_message_id` correlation exists.
// =============================================================================

const http = require('http');
const { SQSClient, ReceiveMessageCommand, DeleteMessageCommand,
        SendMessageCommand } = require('@aws-sdk/client-sqs');
const { Pool } = require('pg');

// ---------------------------------------------------------------------------
// CUSTOMER: EDIT HERE.
// ---------------------------------------------------------------------------
const REGION          = process.env.AWS_REGION || 'eu-north-1';
const BLUE_QUEUE_URL  = process.env.BLUE_QUEUE_URL;
const GREEN_QUEUE_URL = process.env.GREEN_QUEUE_URL;
const PG_URL          = process.env.PG_URL;            // -> your RDS URL
const F5_CALLBACK_URL = process.env.F5_CALLBACK_URL;   // -> your F5 API GW URL
const PORT            = Number(process.env.PORT || 8082);

const sqs  = new SQSClient({ region: REGION });              // auto-instrumented
const pool = new Pool({ connectionString: PG_URL, max: 4 }); // auto-instrumented

const log = (...a) => console.log(new Date().toISOString(), ...a);
const attr = (msg, name) => msg.MessageAttributes?.[name]?.StringValue;

// --------------------------------------------------------------------------
// One-time schema bootstrap. Stands in for your existing RDS tables.
// --------------------------------------------------------------------------
async function initDb() {
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query(`
        CREATE TABLE IF NOT EXISTS hub_messages (
          id              BIGSERIAL PRIMARY KEY,
          hub_message_id  TEXT NOT NULL,
          message_id      TEXT,
          research_id     TEXT,
          payload         JSONB,
          dispatched      BOOLEAN NOT NULL DEFAULT FALSE,
          created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
        )`);
      await pool.query(
        `DELETE FROM hub_messages WHERE created_at < now() - interval '2 hours'`);
      log('db ready');
      return;
    } catch (err) {
      log(`db not ready (attempt ${attempt}): ${err.message}`);
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
}

// =============================================================================
//  BLUE FLOW — step 3+4 of 5:  SQS(blue) -> RDS
// =============================================================================
async function handleBlue(msg) {
  const body = JSON.parse(msg.Body || '{}');
  const header = body.appHeader || {};
  const hubMessageId = attr(msg, 'hub_message_id') || header.hub_message_id;
  const messageId    = attr(msg, 'message_id')     || header.message_id;

  log(`BLUE 3/5 consumed from SQS hub_message_id=${hubMessageId}`);

  // pg auto-instrumentation -> a `db.system=postgresql` span.
  await pool.query(
    `INSERT INTO hub_messages (hub_message_id, message_id, research_id, payload)
     VALUES ($1, $2, $3, $4)`,
    [hubMessageId, messageId, String(header.research_id ?? ''), body]
  );

  log(`BLUE 4/5 written to RDS hub_message_id=${hubMessageId}`);
}

// =============================================================================
//  GREEN FLOW — step 1+2 of 5:  RDS -> SQS(green)
//
//  CUSTOMER: in your infra this is triggered by an RDS event / DB stream /
//  EventBridge schedule. Here it is an HTTP endpoint so the demo's traffic
//  generator can kick it -- which also gives the GREEN trace one clean root
//  span instead of a set of orphaned timer-rooted spans.
// =============================================================================
async function greenDispatch() {
  // Claim up to 5 pending "Tamar answered" rows.
  const { rows } = await pool.query(
    `UPDATE hub_messages SET dispatched = TRUE
      WHERE id IN (SELECT id FROM hub_messages
                    WHERE dispatched = FALSE
                    ORDER BY created_at LIMIT 5)
     RETURNING hub_message_id, message_id, research_id`);

  for (const r of rows) {
    log(`GREEN 1/5 Tamar answer ready hub_message_id=${r.hub_message_id}`);
    // Auto-instrumentation adds the SQS.SendMessage span AND silently injects
    // the `traceparent` MessageAttribute -- this is what keeps the trace alive
    // across the queue.
    await sqs.send(new SendMessageCommand({
      QueueUrl: GREEN_QUEUE_URL,
      MessageBody: JSON.stringify({
        appHeader: {
          hub_message_id: r.hub_message_id,
          message_id: r.message_id,
          research_id: r.research_id,
        },
        data: {
          status: 200,
          message_data: { is_approved: 1, message: 'Update request approved', error_id: 0 },
        },
      }),
      MessageAttributes: {
        hub_message_id: { DataType: 'String', StringValue: r.hub_message_id },
        message_id: { DataType: 'String', StringValue: r.message_id || 'unknown' },
      },
    }));
    log(`GREEN 2/5 published to SQS hub_message_id=${r.hub_message_id}`);
  }
  return rows.length;
}

// =============================================================================
//  GREEN FLOW — step 3+4 of 5:  SQS(green) -> F5 API GW -> clinic
// =============================================================================
async function handleGreen(msg) {
  const body = JSON.parse(msg.Body || '{}');
  const header = body.appHeader || {};
  const hubMessageId = attr(msg, 'hub_message_id') || header.hub_message_id;

  log(`GREEN 3/5 consumed from SQS hub_message_id=${hubMessageId}`);

  // global fetch() runs on undici, which is auto-instrumented: CLIENT span plus
  // automatic `traceparent` injection, so edge-dotnet continues this trace.
  const url = `${F5_CALLBACK_URL}?hub_message_id=${encodeURIComponent(hubMessageId)}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-hub-message-id': hubMessageId },
    body: JSON.stringify(body),
  });
  await res.text();

  log(`GREEN 4/5 dispatched to F5 API GW status=${res.status} hub_message_id=${hubMessageId}`);
}

// --------------------------------------------------------------------------
// Generic long-polling consumer loop (20s long poll == very few SQS requests).
// --------------------------------------------------------------------------
async function consume(queueUrl, label, handler) {
  for (;;) {
    try {
      const out = await sqs.send(new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 5,
        WaitTimeSeconds: 20,
        // IMPORTANT: 'All' is what lets the auto-instrumentation read the
        // `traceparent` MessageAttribute the producer injected. Without it the
        // consumer starts a brand-new, disconnected trace.
        MessageAttributeNames: ['All'],
      }));

      const messages = out.Messages || [];
      // Use .map(): the aws-sdk instrumentation patches this array so each
      // callback runs inside its own "process" span, parented to the producer.
      await Promise.all(messages.map(async (msg) => {
        try {
          await handler(msg);
        } catch (err) {
          log(`${label} handler error: ${err.stack || err.message}`);
        }
        await sqs.send(new DeleteMessageCommand({
          QueueUrl: queueUrl, ReceiptHandle: msg.ReceiptHandle,
        }));
      }));
    } catch (err) {
      log(`${label} receive error: ${err.message}`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

// --------------------------------------------------------------------------
// Tiny HTTP server. The `http` module is auto-instrumented, so this server
// span becomes the clean root of every GREEN trace.
// --------------------------------------------------------------------------
function startHttp() {
  http.createServer(async (req, res) => {
    if (req.method === 'POST' && req.url.startsWith('/tamar/dispatch')) {
      try {
        const n = await greenDispatch();
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ dispatched: n }));
      } catch (err) {
        log(`green dispatch error: ${err.message}`);
        res.writeHead(500); res.end(JSON.stringify({ error: err.message }));
      }
      return;
    }
    if (req.url.startsWith('/healthz')) { res.writeHead(200); res.end('ok'); return; }
    res.writeHead(404); res.end();
  }).listen(PORT, () => log(`http listening on ${PORT}`));
}

(async () => {
  await initDb();
  startHttp();
  log('worker-node starting consumers');
  await Promise.all([
    consume(BLUE_QUEUE_URL,  'BLUE',  handleBlue),
    consume(GREEN_QUEUE_URL, 'GREEN', handleGreen),
  ]);
})();
