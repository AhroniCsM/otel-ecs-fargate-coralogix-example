# OpenTelemetry auto-instrumentation on ECS/EC2 → Coralogix

A minimal, always-on reference implementation of the **Ministry of Health HUB**
flows (`BLUE` and `GREEN`), instrumented with **OpenTelemetry automatic
instrumentation only** — there is not one manual span, tracer or
`opentelemetry` import in any application file.

It answers one question in particular:

> The BLUE and GREEN flows are asynchronous, so each one gets its own Trace ID.
> How do we tie a clinic's request to the answer that comes back to it?

**Answer, verified end to end:** you get three independent correlation
mechanisms, and you need all three. See [Correlating the two flows](#correlating-the-two-flows).

---

## What runs

Everything sits on **one `t4g.small` EC2 instance** in **one ECS cluster**, six
ECS services, `networkMode: host` throughout (so every hop is `localhost` —
no ALB, no NAT gateway, no service discovery, no Cloud Map).

| Your architecture | This repo | Language |
|---|---|---|
| AWS ALB + API Gateway (F5) | `edge-dotnet` :8080 | **.NET 8** |
| BLUE routing Lambda | `hub-python` :8081 | **Python 3.12** |
| SQS (blue) | `moh-hub-otel-blue` | real SQS |
| BLUE Lambda → RDS | `worker-node` | **Node.js 22** |
| RDS | `postgres` :5432 container | *stand-in, see below* |
| RDS change → SQS (green) | `worker-node` :8082 | **Node.js 22** |
| SQS (green) | `moh-hub-otel-green` | real SQS |
| GREEN Lambda → F5 API GW | `worker-node` | **Node.js 22** |
| Outpatient clinic (מרפאת חוץ) | `loadgen` | *uninstrumented on purpose* |
| — | `otel-collector` (ECS **DAEMON**) | Coralogix CDOT |

### The two flows

```
BLUE  (clinic → MoH)
  loadgen ──HTTP──▶ edge-dotnet ──HTTP──▶ hub-python ──▶ SQS(blue) ──▶ worker-node ──▶ RDS
          (clinic)   ALB + API GW          routing λ                    DB-writer λ

GREEN (MoH → clinic)
  loadgen ──HTTP──▶ worker-node ──▶ SQS(green) ──▶ worker-node ──HTTP──▶ edge-dotnet
          (trigger)  RDS→SQS λ                     dispatch λ            F5 API GW → clinic
```

`loadgen` runs forever (one BLUE transaction every 10s, a GREEN trigger every
30s), so there is always live APM data. It is deliberately **not**
instrumented: a real clinic is a third party outside your account, so the root
span of every trace should be *your* edge service — which is exactly what you get.

---

## How the auto-instrumentation is wired (the part you care about)

Each service has **zero** OpenTelemetry code. Look at
[`services/edge-dotnet/Program.cs`](services/edge-dotnet/Program.cs),
[`services/hub-python/app.py`](services/hub-python/app.py) and
[`services/worker-node/index.js`](services/worker-node/index.js) — no imports,
no spans. All of it is Dockerfile + environment variables.

### .NET 8 — [`services/edge-dotnet/Dockerfile`](services/edge-dotnet/Dockerfile)

Download the agent, then set five environment variables. The CLR profiler
rewrites IL at JIT time.

```dockerfile
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
RUN curl -sSfL .../otel-dotnet-auto-install.sh -o /tmp/i.sh && sh /tmp/i.sh

ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/native/OpenTelemetry.AutoInstrumentation.Native.so
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
```

Gives you: ASP.NET Core server spans, `HttpClient` client spans (with automatic
`traceparent` injection), `ILogger` records over OTLP, and runtime metrics.

> The agent's own `instrument.sh` exports exactly these. We set them explicitly
> so you can see what is required. **Note:** `DOTNET_ADDITIONAL_DEPS` and
> `DOTNET_SHARED_STORE` appear in older docs — v1.16 no longer uses them.

### Python 3.12 — [`services/hub-python/Dockerfile`](services/hub-python/Dockerfile)

One pip package, one command prefix.

```dockerfile
RUN pip install opentelemetry-distro opentelemetry-exporter-otlp \
                opentelemetry-instrumentation-{fastapi,botocore,psycopg2,logging}
ENTRYPOINT ["opentelemetry-instrument", "uvicorn", "app:app", ...]
```

Gives you: FastAPI server spans, botocore/SQS spans, psycopg2 `db.*` spans,
and `trace_id` on every stdlib log record.

> **On Lambda instead of ECS:** attach the ADOT Lambda layer and set
> `AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-instrument`. Same auto-instrumentation.

### Node.js 22 — [`services/worker-node/Dockerfile`](services/worker-node/Dockerfile)

One npm package, one environment variable.

```dockerfile
ENV NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
```

Gives you: `http`/`undici` spans, **real SQS messaging spans**, `pg` spans.

> ⚠️ **Version pinning is not optional here.**
> `@opentelemetry/instrumentation-aws-sdk` patches the AWS SDK's internal
> `@smithy/*` packages. We originally pinned `auto-instrumentations-node@0.55`
> against `@aws-sdk/client-sqs@3.1116`; the instrumentation hooks
> `@smithy/smithy-client`, which newer SDKs no longer ship, so it **silently
> failed to patch** — we lost every SQS span and all SQS trace propagation, with
> no error anywhere. After any upgrade, confirm you still see
> `<queue-name> send` / `<queue-name> receive` spans.

### The environment variables that matter (identical in all three services)

Set in [`infra/cloudformation/02-ecs.yaml`](infra/cloudformation/02-ecs.yaml):

```bash
OTEL_SERVICE_NAME=edge-dotnet                     # → Coralogix SUBSYSTEM
OTEL_RESOURCE_ATTRIBUTES=service.namespace=moh-hub-poc,deployment.environment=poc
                                                  # service.namespace → Coralogix APPLICATION
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 # the DAEMON collector on the same host
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_SAMPLER=always_on                     # 100% — NO SAMPLING
OTEL_PROPAGATORS=tracecontext,baggage
```

There is no sampler anywhere in the collector config either — **every span
reaches Coralogix.**

### The collector — [`infra/otel-collector/otel-config.yaml`](infra/otel-collector/otel-config.yaml)

Runs as an ECS **DAEMON** service in host network mode: one collector per EC2
instance, reachable at `localhost:4318`. This is the pattern from the
[Coralogix ECS-EC2 docs](https://coralogix.com/docs/opentelemetry/configuration-options/aws-ecs-ec2-using-opentelemetry/).

```yaml
exporters:
  coralogix:
    domain: "${env:CORALOGIX_DOMAIN}"          # e.g. eu2.coralogix.com
    private_key: "${env:CORALOGIX_PRIVATE_KEY}"
    application_name_attributes: [service.namespace]
    subsystem_name_attributes: [service.name]
```

The key is stored as an **SSM Parameter Store SecureString** and injected by the
ECS agent at container start. It is never in git, never in a task definition.

---

## Correlating the two flows

### 1. Same Trace ID — every synchronous HTTP hop

W3C `traceparent` is injected and extracted automatically. Verified:

```
ROOT edge-dotnet   POST /api/v1/hub/messages
       edge-dotnet   POST                        (HttpClient)
         hub-python    POST /process             ← same trace, different service
           hub-python    pg.query:SELECT
           hub-python    SQS.SendMessage
```

### 2. Span links (`FOLLOWS_FROM`) — across SQS, where the SDK supports it

Node's auto-instrumentation injects `traceparent` into the SQS
`MessageAttributes` on send. Confirmed by reading a live message off the queue:

```json
"MessageAttributes": {
  "hub_message_id": {...}, "message_id": {...},
  "traceparent": { "StringValue": "00-8c34f7255d2ddb45d39b1605cc12de85-9216930c49a593dd-01" }
}
```

On receive, the current instrumentation adds a **span link** (not a parent), so
Coralogix shows:

```
flattenedLinks: traceId-c7d2ddbb3e6087c9c7cdde7cd463a65b:spanId-3af13994859df1ee:linkType-FOLLOWS_FROM
```

> Requires `MessageAttributeNames: ['All']` on `ReceiveMessage`. Without it the
> attributes are not returned and the consumer starts a disconnected trace.

### 3. The business GUID — works across **every** boundary

**This is the mechanism you must build on**, because mechanism 2 is not
universally available:

| Producer SDK | Injects `traceparent` into SQS? | Consumer SDK | Extracts it? |
|---|---|---|---|
| **Node** `@opentelemetry/instrumentation-aws-sdk` | ✅ yes | **Node** | ✅ yes, as a span **link** |
| **Python** `opentelemetry-instrumentation-botocore` | ❌ **no** | **Python** | ❌ no |
| **.NET** `OpenTelemetry.Instrumentation.AWS` | ✅ yes | **.NET** | opt-in |

We read the Python SQS extension's source to confirm: it only sets attributes
(`messaging.system`, `aws.queue_url`, `messaging.message_id`) and never touches
propagation. **A Python producer therefore always breaks the trace at the
queue.** That is precisely the situation you described, and no amount of
configuration fixes it.

So the applications carry `hub_message_id` in the request URL and an
`x-hub-message-id` header, and the **collector** — not the application — lifts
it onto the span:

```yaml
transform/hub_message_id:
  trace_statements:
    - context: span
      statements:
        - 'set(cache["a"], ExtractPatterns(attributes["url.full"], "hub_message_id=(?P<id>[0-9a-fA-F-]{36})")) where attributes["url.full"] != nil'
        - 'set(attributes["hub.message_id"], cache["a"]["id"]) where cache["a"] != nil'
        # ...plus url.query / http.url / http.target for older semconv versions
```

Why the URL? Because **every** auto-instrumentation records the request URL on
its HTTP spans, in every language, with no configuration. Put the GUID where
the instrumentation is already looking and you get it for free.

The same processor also promotes it on **logs**, so `hub.message_id` +
`trace_id` sit on every log record and you can go GUID → log → trace.

**Result** — one GUID resolves to exactly the two traces of the transaction:

```
### one business GUID -> how many traces?
  "d52399eb-d586-4980-8fde-7266efedf33c",  traces=2
  "e3d6ddc7-f753-4413-9620-b49cc39d6be2",  traces=2
  "cdacebab-2b02-44af-91ca-3826c78eb75e",  traces=2
```

### Which field? `Hub_Message_ID` or `Message_ID`?

Both are carried end to end (URL, header, JSON body, SQS `MessageAttributes`).
The repo treats **`hub_message_id`** as the join key and promotes it to the span
attribute `hub.message_id`. When your developer confirms which field is the true
unique identifier, it is a **one-line change in the collector config** — no
application change, no redeploy of any service.

---

## Deploy

Prerequisites: `aws` CLI, Docker (with buildx), and a Coralogix
**Send-Your-Data** API key.

```bash
export CORALOGIX_PRIVATE_KEY=cxtp_xxxxxxxx
export CORALOGIX_DOMAIN=eu2.coralogix.com     # your region
export AWS_REGION=eu-north-1

./scripts/deploy.sh
```

That stores the key in SSM, deploys both CloudFormation stacks, and builds and
pushes all five images. Traffic starts immediately.

### Verify from the terminal

```bash
./scripts/verify-traces.sh          # uses cx-cli
```

### Try it locally first (~2 minutes)

```bash
cp .env.example .env && $EDITOR .env
docker compose up --build
```

Same containers, same environment variables, real SQS, real Coralogix.

### Tear down

```bash
./scripts/destroy.sh
```

---

## Cost

| Item | Monthly (eu-north-1) |
|---|---|
| 1 × `t4g.small` EC2 (Graviton) | ~$12 |
| 30 GB gp3 EBS | ~$2.50 |
| SQS (~2 queues, 20s long polling) | $0 — inside free tier |
| ECR (5 images, keep-last-3 lifecycle) | <$0.50 |
| CloudWatch Logs (3-day retention) | <$0.50 |
| ALB / NAT / RDS | **$0 — none used** |

**~$15/month.** Deliberate choices: `host` networking instead of an ALB, a
Postgres container instead of RDS, Graviton instead of x86, and no NAT gateway.

---

## Editing this for your own infrastructure

Everything you need to change is marked `CUSTOMER:` in the source. The short list:

1. **`infra/cloudformation/02-ecs.yaml`** — delete the `Postgres*` and
   `Loadgen*` task definitions and services. Point `PG_DSN` / `PG_URL` at your
   real RDS endpoint and `F5_CALLBACK_URL` at your real F5 API Gateway.
2. **`CoralogixDomain`** — your region's domain.
3. **`HUB_ROUTER_URL`** — your internal API Gateway / Lambda URL instead of
   `localhost:8081`.
4. **SQS FIFO** — the queues here are Standard for simplicity. Propagation is
   identical on FIFO (the `traceparent` rides in a `MessageAttribute` either
   way); add `FifoQueue: true`, a `.fifo` name suffix, and a `MessageGroupId`.
5. **Multiple EC2 instances** — nothing to change. The collector is a DAEMON, so
   each new instance gets its own, and `localhost:4318` keeps working. But
   `host` networking means one task per port per instance, so if you scale out
   the applications, switch them to `awsvpc`/`bridge` and point
   `OTEL_EXPORTER_OTLP_ENDPOINT` at the EC2 private IP
   (`ECS_CONTAINER_METADATA` / `169.254.169.254`) instead of `localhost`.

## Known limitations

- **Node `console.log` is not shipped over OTLP.** OpenTelemetry Node only
  auto-instruments `winston`/`bunyan`/`pino`. `worker-node`'s logs reach
  CloudWatch but not Coralogix. Use a supported logger if you need them.
- **Python `logging.basicConfig()` is a no-op** under `opentelemetry-instrument`
  — the OTLP handler is already attached to the root logger, so `basicConfig`
  bails out and the root level stays `WARNING`, silently dropping all your INFO
  logs. Call `logging.getLogger().setLevel(logging.INFO)` explicitly. This bit
  us during development; see the comment in `app.py`.
- **`.NET ILogger` bodies are message *templates*.** The rendered values live in
  log attributes, which is why the collector reads the `hub_message_id`
  attribute directly for .NET and parses the body for Python.
- **The Postgres container is ephemeral** (`PGDATA=/tmp/pgdata`). Restarting the
  task loses the data. That is intentional — it is a stand-in for RDS.
- **First spans take ~2–4 minutes** to become queryable after deploy.
