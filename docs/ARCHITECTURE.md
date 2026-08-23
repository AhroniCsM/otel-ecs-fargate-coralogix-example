# Architecture & trace topology

## Mapping to the Ministry of Health POC diagram

```
                        ┌──────────────────── MoH HUB (this repo) ─────────────────────┐
                        │                                                              │
   מרפאת חוץ            │   edge-dotnet          hub-python           worker-node      │
   (outpatient clinic)  │   ALB + API GW         routing λ            DB-writer λ      │
        │               │   [.NET 8]             [Python 3.12]        [Node.js 22]     │
        │  BLUE         │       │                     │                    │           │
        └───── HTTP ────┼──────▶│──── HTTP ──────────▶│──── SQS(blue) ────▶│           │
                        │       │                     │                    ▼           │
                        │       │                     │                 postgres       │
                        │       │                     │                 ("RDS")        │
                        │       │                                          │           │
                        │  GREEN│                                          │           │
        ┌───────────────┼───────│◀─── HTTP ───┬─── SQS(green) ◀────────────┘           │
        │               │   F5 API GW         │      RDS→SQS λ                         │
        ▼               │                 dispatch λ  [Node.js 22]                     │
   clinic Agent         │                 [Node.js 22]                                 │
                        │                                                              │
                        │   otel-collector (ECS DAEMON, host net, :4317/:4318)          │
                        └───────────────────────────┬──────────────────────────────────┘
                                                    │  OTLP → coralogix exporter
                                                    ▼
                                            Coralogix (eu2)
```

`loadgen` plays the clinic on both sides. It is **not** instrumented, so the
root span of every trace is one of MoH's own services.

## Trace topology as it actually appears in Coralogix

Verified with `cx-cli` against a live ECS-EC2 deployment.

### BLUE — two traces, joined by `hub.message_id`

```
TRACE A  (synchronous part)
  edge-dotnet   POST /api/v1/hub/messages          ← ROOT     hub.message_id=<GUID>
    edge-dotnet   POST                (HttpClient)             hub.message_id=<GUID>
      hub-python    POST /process      (FastAPI)               hub.message_id=<GUID>
        hub-python    pg.query:SELECT  (psycopg2 → RDS)
        hub-python    SQS.SendMessage  (botocore)   ← trace ENDS here:
                                                     botocore does not inject
                                                     traceparent into SQS
── SQS(blue) ─────────────────────────────────────────────────────────────────
TRACE B
  worker-node   moh-hub-otel-blue receive          ← ROOT (no link: nothing was injected)
    worker-node   pg.query:INSERT hub  (pg → RDS)
```

### GREEN — two traces, joined by `hub.message_id` **and** a span link

```
TRACE C
  worker-node   POST /tamar/dispatch               ← ROOT
    worker-node   pg.query:UPDATE hub  (claim pending rows)
    worker-node   moh-hub-otel-green send          ← INJECTS traceparent ✅
── SQS(green) ────────────────────────────────────────────────────────────────
TRACE D
  worker-node   moh-hub-otel-green receive         ← ROOT + span LINK
                                                     FOLLOWS_FROM → TRACE C
    worker-node   POST                (undici/fetch)          hub.message_id=<GUID>
      edge-dotnet   POST /f5/clinic-callback                   hub.message_id=<GUID>
```

## The three correlation mechanisms, and where each one works

| Boundary | Same trace ID | Span link | `hub.message_id` |
|---|---|---|---|
| .NET → Python (HTTP) | ✅ | — | ✅ |
| Python → SQS → Node | ❌ | ❌ | ✅ |
| Node → SQS → Node | ❌ | ✅ `FOLLOWS_FROM` | ✅ |
| Node → .NET (HTTP) | ✅ | — | ✅ |

The GUID is the only column with no gaps. That is why the collector promotes it.

## Ports (all on the single EC2 instance, `networkMode: host`)

| Port | Service |
|---|---|
| 4317 / 4318 | otel-collector — OTLP gRPC / HTTP |
| 8888 | otel-collector — own Prometheus metrics |
| 13133 | otel-collector — health check |
| 8080 | edge-dotnet |
| 8081 | hub-python |
| 8082 | worker-node (green trigger) |
| 5432 | postgres ("RDS") |

The security group has **no inbound rules**. Nothing is reachable from outside
the instance; use SSM Session Manager for a shell.
