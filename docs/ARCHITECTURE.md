# Architecture & trace topology

## Mapping to the Ministry of Health POC diagram

```
                        ┌──────────────── MoH HUB (this repo) ─────────────────┐
                        │                                                      │
   מרפאת חוץ            │   edge-dotnet          hub-python                   │
   (outpatient clinic)  │   ALB + API GW         routing λ                    │
        │               │   [.NET 8]             [Python 3.12]                │
        │  BLUE         │       │                     │                       │
        └───── HTTP ────┼──────▶│──── HTTP ──────────▶│──── SQS(blue) ──▶     │
                        │       │                     │                       │
                        │                                                      │
                        │   otel-collector (ECS Fargate service,               │
                        │   Service Connect: otel-collector:4317/:4318)        │
                        └───────────────────────────┬──────────────────────────┘
                                                    │  OTLP → coralogix exporter
                                                    ▼
                                            Coralogix (eu2)
```

`loadgen` plays the clinic. It is **not** instrumented, so the root span of
every trace is one of MoH's own services.

## Trace topology as it actually appears in Coralogix

Verified with `cx-cli` against a live ECS Fargate deployment.

### BLUE — one continuous trace, terminating at the SQS producer span

```
TRACE A
  edge-dotnet   POST /api/v1/hub/messages          ← ROOT     hub.message_id=<GUID>
    edge-dotnet   POST                (HttpClient)             hub.message_id=<GUID>
      hub-python    POST /process      (FastAPI)               hub.message_id=<GUID>
        hub-python    SQS.SendMessage  (botocore)   ← trace ENDS here:
                                                     botocore does not inject
                                                     traceparent into SQS
── SQS(blue) ─────────────────────────────────────────────────────────────────
                                                     (nothing consumes this
                                                      queue in this demo)
```

Unlike a fan-out across an async boundary with its own consumer, there is only
one trace here — the two HTTP hops (.NET → Python) share it automatically via
W3C `traceparent`. The SQS send is the deliberate stopping point of the demo:
it is where a real consumer (a Lambda, another ECS service) would pick up the
message and start a **new**, disconnected trace, because `botocore`'s SQS
instrumentation does not propagate `traceparent` into the message.

## Correlation mechanisms, and where each one works

| Boundary | Same trace ID | `hub.message_id` |
|---|---|---|
| .NET → Python (HTTP) | ✅ | ✅ |
| Python → SQS (send) | ✅ (still the producer's own trace) | ✅ |
| SQS → any consumer you add | ❌ (botocore does not inject `traceparent`) | ✅, if the consumer also promotes it |

`hub.message_id` is the only column with no gaps — which is why it is useful
even when everything is already on one trace: it lets you search by business
transaction instead of by trace ID, and it is what would still join this trace
to a downstream consumer's trace if you added one.

## Ports (all reachable by ECS Service Connect DNS name, not by IP)

| Port | Service |
|---|---|
| 4317 / 4318 | otel-collector — OTLP gRPC / HTTP |
| 8888 | otel-collector — own Prometheus metrics |
| 13133 | otel-collector — health check |
| 8080 | edge-dotnet |
| 8081 | hub-python |

All four services share one security group with self-referencing ingress
(any task in the group can reach any other task on any port); nothing is
reachable from outside the VPC except each task's own public IP for outbound
internet access (ECR / SQS / Coralogix). Use
`aws ecs execute-command` for a shell instead of SSH.
