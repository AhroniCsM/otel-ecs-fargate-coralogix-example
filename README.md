# OpenTelemetry auto-instrumentation on ECS Fargate → Coralogix

## What this guide teaches you

How to get **OpenTelemetry automatic instrumentation** — zero application
code, zero manual spans — working for **.NET 8** and **Python 3.12** services
running on **AWS ECS Fargate**, shipping traces, metrics and logs to
Coralogix with full APM. Everything you need is here: the exact Dockerfile
changes for each language ([`services/edge-dotnet/Dockerfile`](services/edge-dotnet/Dockerfile),
[`services/hub-python/Dockerfile`](services/hub-python/Dockerfile)), the
environment variables that wire it up, the ECS Fargate task/service definitions
(`awsvpc` networking, ECS Service Connect for service discovery, the
collector as its own Fargate service), and a working, deployable example you
can run end to end and adapt to your own services.

The example below (a "Ministry of Health HUB" scenario, two services passing
a request through to SQS) is just the vehicle for demonstrating the pattern —
swap it for your own services once you see how the instrumentation and the
Fargate wiring fit together. It is instrumented with **OpenTelemetry
automatic instrumentation only** — there is not one manual span, tracer or
`opentelemetry` import in any application file.

It answers one question in particular:

> Two different language runtimes (.NET and Python), two hops of HTTP, one SQS
> hand-off at the end. How much of that shows up in Coralogix if you write
> **zero** OpenTelemetry code?

**Answer, verified end to end:** all of it — one continuous trace across both
services, full APM (service map, RED metrics, latency), and a business GUID
promoted onto every span and log line so you can search by transaction
instead of by trace ID. See [Correlating request and logs](#correlating-request-and-logs).

---

## What runs

One ECS **Fargate** cluster, four services, wired together with **ECS Service
Connect** (each task gets its own ENI; service-to-service calls resolve by
name — `http://hub-python:8081`, `http://otel-collector:4318` — instead of
`localhost`).

| Your architecture | This repo | Language |
|---|---|---|
| AWS ALB + API Gateway (F5) | `edge-dotnet` :8080 | **.NET 8** |
| BLUE routing Lambda | `hub-python` :8081 | **Python 3.12** |
| SQS (blue) | `moh-hub-otel-blue` | real SQS |
| Outpatient clinic (מרפאת חוץ) | `loadgen` | *uninstrumented on purpose* |
| — | `otel-collector` (ECS **Fargate service**) | Coralogix CDOT |

### The flow

```
BLUE  (clinic → MoH)
  loadgen ──HTTP──▶ edge-dotnet ──HTTP──▶ hub-python ──▶ SQS(blue)
          (clinic)   ALB + API GW          routing λ      (terminus of the demo)
```

`loadgen` runs forever (one BLUE transaction every 10s), so there is always
live APM data. It is deliberately **not** instrumented: a real clinic is a
third party outside your account, so the root span of every trace should be
*your* edge service — which is exactly what you get.

---

## How the auto-instrumentation is wired (the part you care about)

Each service has **zero** OpenTelemetry code. Look at
[`services/edge-dotnet/Program.cs`](services/edge-dotnet/Program.cs) and
[`services/hub-python/app.py`](services/hub-python/app.py) — no imports, no
spans. All of it is Dockerfile + environment variables.

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
                opentelemetry-instrumentation-{fastapi,botocore,logging}
ENTRYPOINT ["opentelemetry-instrument", "uvicorn", "app:app", ...]
```

Gives you: FastAPI server spans, botocore/SQS spans, and `trace_id` on every
stdlib log record.

> **On Lambda instead of ECS:** attach the ADOT Lambda layer and set
> `AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-instrument`. Same auto-instrumentation.

### The environment variables that matter (identical in both services)

Set in [`infra/cloudformation/02-ecs.yaml`](infra/cloudformation/02-ecs.yaml):

```bash
OTEL_SERVICE_NAME=edge-dotnet                            # → Coralogix SUBSYSTEM
OTEL_RESOURCE_ATTRIBUTES=service.namespace=moh-hub-poc,deployment.environment.name=ecs-stg-exmaple,deployment.environment=ecs-stg-exmaple
                                                          # service.namespace → Coralogix APPLICATION
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318   # the collector, via ECS Service Connect
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_TRACES_EXPORTER=otlp
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_TRACES_SAMPLER=always_on                            # 100% — NO SAMPLING
OTEL_PROPAGATORS=tracecontext,baggage
```

There is no sampler anywhere in the collector config either — **every span
reaches Coralogix.**

### The collector — [`infra/otel-collector/otel-config.yaml`](infra/otel-collector/otel-config.yaml)

Runs as a normal ECS Fargate **REPLICA** service (Fargate has no DAEMON
scheduling strategy), published via **ECS Service Connect** as
`otel-collector` so every application task can reach it at
`http://otel-collector:4318` regardless of which ENI it actually landed on.

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

## Correlating request and logs

### Same Trace ID — every synchronous HTTP hop

W3C `traceparent` is injected and extracted automatically across both HTTP
hops. Verified:

```
ROOT edge-dotnet   POST /api/v1/hub/messages
       edge-dotnet   POST                        (HttpClient)
         hub-python    POST /process             ← same trace, different service
           hub-python    SQS.SendMessage
```

The trace ends at the SQS producer span: `botocore`'s auto-instrumentation
records the send but does not inject `traceparent` into the message, so if you
add a consumer later, its trace will start fresh at the queue. That is a
property of the Python SQS instrumentation, not something this demo works
around.

### The business GUID — a second correlation axis, independent of trace ID

Even with everything on one trace, you often want to search by a **business**
identifier instead of a trace ID — "show me every span and log line for
transaction X", from a support ticket or a customer email. So the applications
carry `hub_message_id` in the request URL and an `x-hub-message-id` header,
and the **collector** — not the application — lifts it onto the span:

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
`trace_id` sit on every log record and you can go GUID → log → trace, or
trace → log, with one search.

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
pushes all four images. Traffic starts immediately.

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

### Stop / start without destroying

```bash
./scripts/scale.sh stop      # every task stopped, cost ~= $0
./scripts/scale.sh start     # back up, traffic resumes in ~1 minute
./scripts/scale.sh status
```

> **Heads-up if you run this in a Coralogix AWS account.** There is an
> account-level automation (IAM principal `eks-ecs-auto-scaler`) that scales
> **every ECS service in the account to `desiredCount: 0`** on a schedule — it
> hit this lab at 01:00 local time, including services in unrelated clusters.
> If your demo is mysteriously dead in the morning, that is why. Run
> `./scripts/scale.sh start` before showing anything to a customer.

### Tear down

```bash
./scripts/destroy.sh
```

---

## Editing this for your own infrastructure

Everything you need to change is marked `CUSTOMER:` in the source. The short list:

1. **`infra/cloudformation/02-ecs.yaml`** — delete the `Loadgen*` task
   definition and service; your real clinics are the traffic.
2. **`CoralogixDomain`** — your region's domain.
3. **`HUB_ROUTER_URL`** — your internal API Gateway / Lambda URL instead of
   `http://hub-python:8081`.
4. **SQS FIFO** — the queue here is Standard for simplicity. Propagation is
   identical on FIFO (the `traceparent` rides in a `MessageAttribute` either
   way); add `FifoQueue: true`, a `.fifo` name suffix, and a `MessageGroupId`.
5. **Scaling out** — bump `DesiredCount` and/or add more subnets (one per AZ)
   to `NetworkConfiguration.AwsvpcConfiguration.Subnets`. Nothing else changes:
   every task already reaches the others by Service Connect name, not by IP,
   so adding tasks or AZs is transparent to the application code.
6. **A private VPC instead of a public subnet** — drop `AssignPublicIp` and
   add a NAT gateway (or VPC endpoints for ECR/SQS/S3/CloudWatch Logs), since
   Fargate tasks otherwise need a public IP to reach those services.

## Full APM, not just traces

Traces alone do not populate Coralogix APM. Two extra pieces of **collector**
config (no application change) do:

**1. Span metrics** — the `spanmetrics` connector derives RED metrics from the
spans you are already sending, which is what drives the APM latency, throughput
and error-rate charts. Verified live:

```
$ cx metrics query 'sum by (service_name) (increase(traces_span_metrics_calls_total[10m]))'
  "edge-dotnet","153"
  "hub-python","255"
```

The metric family Coralogix receives is:

| Metric | Use |
|---|---|
| `traces_span_metrics_calls_total` | throughput + error rate |
| `traces_span_metrics_duration_ms_bucket` | latency percentiles |
| `traces_span_metrics_duration_ms_count` / `_sum` | averages |

> **Cost warning, and it matters.** Every `dimensions:` entry multiplies the
> time-series count. The dimensions here (`http.request.method`,
> `http.response.status_code`, `messaging.system`) are all low-cardinality.
> **Never add `hub.message_id`** — it is a GUID per transaction, so it would
> create one time series per request. Keep the GUID on spans, off metrics.

**2. Environment separation** — `deployment.environment.name` becomes the
Environment facet in APM, which is how you keep stg and prod apart in one
account. Set via the `DeploymentEnvironmentName` CloudFormation parameter
(currently `ecs-stg-exmaple`) and verified arriving:

```
$ cx spans "... | groupby $d.process.tags['deployment.environment.name'] as env agg count()"
  "ecs-stg-exmaple",54
```
