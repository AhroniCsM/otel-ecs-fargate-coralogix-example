# OpenTelemetry auto-instrumentation on ECS Fargate → Coralogix

## What this guide teaches you

How to get **OpenTelemetry automatic instrumentation** — zero application
code, zero manual spans — working for **.NET 6** and **Python 3.12** services
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
| **Sponsor / BackOffice** ECS containers — where tracing starts | `edge-dotnet` :8080 | **.NET 6** |
| HUB routing Lambdas (all Python) | `hub-python` :8081 | **Python 3.12** |
| SQS (blue) | `moh-hub-otel-blue` | real SQS |
| Outpatient clinic (מרפאת חוץ) | `loadgen` | *uninstrumented on purpose* |
| — | `otel-collector` (ECS **Fargate service**) | Coralogix CDOT |

> **The .NET Lambda on the MoH-infrastructure side** (incl. the green-route
> path for repeated calls) is instrumented the same way, only packaged
> differently: attach the OTel/ADOT **Lambda layer** for .NET instead of
> baking the agent into a Dockerfile, and set `AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-instrument`
> plus the exact same `OTEL_*` environment variables you see below. Python
> Lambdas: same story with the Python ADOT layer.
>
> **Genericity / Terraform:** nothing in this repo is hand-crafted per
> service. The entire integration is (a) a fixed block of `OTEL_*`
> environment variables per task definition, (b) one collector config file,
> (c) one SSM SecureString for the key. All three translate 1:1 into
> `aws_ecs_task_definition` / `aws_ssm_parameter` Terraform resources — the
> CloudFormation in `infra/` is the reference implementation to port.

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

### .NET 6 — [`services/edge-dotnet/Dockerfile`](services/edge-dotnet/Dockerfile)

Download the agent, then set seven environment variables. The CLR profiler
rewrites IL at JIT time.

```dockerfile
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
RUN curl -sSfL .../v1.9.0/otel-dotnet-auto-install.sh -o /tmp/i.sh && sh /tmp/i.sh

ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/native/OpenTelemetry.AutoInstrumentation.Native.so
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
ENV DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps   # .NET 6 only
ENV DOTNET_SHARED_STORE=/otel-dotnet-auto/store               # .NET 6 only
```

Gives you: ASP.NET Core server spans, `HttpClient` client spans (with automatic
`traceparent` injection), `ILogger` records over OTLP, and runtime metrics.

> **Version pin matters on .NET 6:** agent **v1.9.0 is the last release that
> supports .NET 6/7** — v1.10.0 removed them after their end of support. On
> .NET 6 the agent also needs `DOTNET_ADDITIONAL_DEPS` + `DOTNET_SHARED_STORE`
> (that is how it injects its updated `System.Diagnostics.DiagnosticSource`
> into the app); on .NET 8+ with agent v1.10+ those two vars are gone and you
> set only the first four. Application code is identical either way.

### Troubleshooting .NET 6 — every real-world failure mode, mapped

These are actual errors hit while instrumenting a production .NET 6.0.36
service on ECS with an init-container that downloads the agent into a shared
volume. Each one has a specific cause. The Dockerfile in this repo is the
combination that works; use this table when your variation of it doesn't.

| Error you see | Agent | Cause | Fix |
|---|---|---|---|
| `Rule Engine: MinSupportedFrameworkVersionValidator ... '6.0.36 is not supported'` | v1.16.0, v1.10.0 | Agent v1.10.0+ removed .NET 6/7 support (EOL) | Pin **v1.9.0** — the last version that supports .NET 6 |
| App exits **code 139 (SIGSEGV)** with `CORECLR_*` set | v1.9.0 | The native profiler `.so` doesn't match the container: **x64 agent in an arm64 task (or vice versa)**, or a **glibc build in an Alpine/musl image**. Typical with init-container downloads where the download logic picks the wrong build | Match `CORECLR_PROFILER_PATH` to the app image's arch/libc (`linux-x64` / `linux-arm64` / `linux-musl-*`). Baking the install into the app image (as here) makes this impossible to get wrong — the install script runs on the target image itself |
| App healthy, **zero telemetry**; agent log shows `CLR profiler was not correctly loaded into the process` + `Rule 'Native profiler diagnoser' failed` | v1.9.0 on **arm64** | **Measured on this exact lab:** the v1.9.0 `linux-arm64` native profiler links against **glibc 2.32–2.35** (built on Ubuntu 22.04), but every default .NET 6 image is Debian 11 "bullseye" = **glibc 2.31**. `dlopen` fails, the rule engine aborts, and the agent disables itself *completely* — including the managed part. `ldd OpenTelemetry.AutoInstrumentation.Native.so` inside the container shows the missing `GLIBC_2.3x` symbols. x64 profiler builds target an older glibc and don't hit this | Use the **`-jammy`** base images (`sdk:6.0-jammy`, `aspnet:6.0-jammy` — Ubuntu 22.04, glibc 2.35), as this repo's Dockerfile does. The Dockerfile also runs `ldd` on the `.so` at **build time**, so an incompatible base fails the build instead of silently shipping an uninstrumented app |
| `MissingMethodException: ...LoggingBuilderExtensions.AddConfiguration(...)` at `WebApplication.CreateBuilder` | v1.9.0, startup-hook only | `DOTNET_ADDITIONAL_DEPS` is set but the **shared store contents don't match** — partial copy, wrong layout, or `DOTNET_SHARED_STORE` pointing at the wrong root. The runtime then binds 8.0.0 deps entries against assemblies it can't find, poisoning the default load context | Ship `AdditionalDeps/` and `store/` **exactly as unpacked** by the agent installer and point both vars at them. Never copy selectively; the store layout (`store/<arch>/<tfm>/...`) must survive intact |
| `Error in StartupHook initialization ... TypeInitializationException ... Loader` (or `FileNotFoundException: Microsoft.Extensions.Logging.Abstractions, Version=8.0.0.0`) | v1.9.0, no deps/store | On .NET 6 the agent's Loader depends on `Microsoft.Extensions.Logging.Abstractions 8.0.0.0`, which .NET 6 doesn't have. `DOTNET_ADDITIONAL_DEPS` + `DOTNET_SHARED_STORE` are **how it gets injected** — they are *required* on .NET 6, not optional | Set both vars (see Dockerfile). This is the single most common .NET 6 mistake |
| Log shows a mangled path like `LoaderFolderLocation: /otel-auto-instrumentation/net?` | any | A stray character (CRLF, quote, `?`) in the env-var value — usually from copy-pasting into a task-definition JSON | Re-type the values; diff against the six `ENV` lines in this repo's Dockerfile |
| A **third-party library** blows up at startup with a nested `TypeInitializationException` → `...OpenTelemetry.AutoInstrumentation.Loader.Loader...` → `FileNotFoundException: System.Diagnostics.DiagnosticSource, Version=8.0.0.0` (seen with IronPDF's license warmup) | v1.9.0 | The library is a **bystander**: it triggered an `AssemblyResolve` event, the agent's Loader initialized lazily inside that event, and the Loader died because `DOTNET_ADDITIONAL_DEPS` is missing (`DOTNET_SHARED_STORE` alone does nothing). The library's own assembly load then fails as collateral damage | Set **both** vars — or, for dependency-heavy apps where AdditionalDeps itself causes conflicts, use the app-local alternative below |
| Traces arrive but the URL query values on .NET spans read `hub_message_id=Redacted` — the GUID never lands on the span | any | The .NET instrumentation **redacts query-string values by default** (privacy). Your correlation GUID travels in the query string, so it's scrubbed before the collector ever sees it | Set `OTEL_DOTNET_EXPERIMENTAL_ASPNETCORE_DISABLE_URL_QUERY_REDACTION=true` and `OTEL_DOTNET_EXPERIMENTAL_HTTPCLIENT_DISABLE_URL_QUERY_REDACTION=true` on the .NET task (see `02-ecs.yaml`) — justified here because the GUID is a business id, not a secret |
| Everything boots, agent log says `MinSupportedFrameworkRule evaluation success`, still no traces | v1.9.0 | The agent is fine — the problem is downstream (collector unreachable, wrong key, or stale ECS Service Connect endpoints) | See the Service Connect note below and the collector section |

#### Dependency-heavy apps (Umbraco, IronPDF, …): the app-local alternative to AdditionalDeps

`DOTNET_ADDITIONAL_DEPS` + `DOTNET_SHARED_STORE` inject the agent's 8.0
assemblies at the **host level**, process-wide, with no NuGet mediation. On a
minimal app that's clean. On an app that pins dozens of 6.x
`Microsoft.Extensions.*` packages (an Umbraco site, say), the host-level merge
can produce a mixed 6.x/8.0 assembly set and the app dies at
`WebApplication.CreateBuilder` with `MissingMethodException` — while removing
the two vars kills the agent's Loader instead (the table above). Both paths
lose.

**The verified way out: move the resolution from the host to NuGet.** Delete
both env vars (`DOTNET_ADDITIONAL_DEPS` *and* `DOTNET_SHARED_STORE`) and add
three references to the application project:

```xml
<ItemGroup>
  <!-- Exactly the closure the agent's AdditionalDeps would have injected,
       but resolved by NuGet at build time, so conflicts with the rest of
       your dependency graph surface as restore warnings instead of runtime
       crashes. All three target net6.0. -->
  <PackageReference Include="System.Diagnostics.DiagnosticSource" Version="8.0.1" />
  <PackageReference Include="Microsoft.Extensions.Logging.Configuration" Version="8.0.1" />
  <PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="8.0.1" />
</ItemGroup>
```

These three pull, app-locally, the exact 12-package closure the agent's store
ships (`Logging` chain, `Options`, `Configuration` + `Binder`, `Primitives`,
`DiagnosticSource`). Verified on this repo's edge service: with the three
references and **no** deps/store vars, the agent logs
`StartupHook initialized successfully` and exports spans + ILogger records
normally. Keep `DOTNET_STARTUP_HOOKS` (and the `CORECLR_*` trio if you want
byte-code instrumentations); everything else in the Dockerfile stays the same.

Two more things worth knowing:

* **How to verify the agent attached** before blaming anything else: the agent
  writes `/var/log/opentelemetry/dotnet/*.log` inside the container. A healthy
  .NET 6 startup shows `MinSupportedFrameworkRule evaluation success` plus a
  *warning* that .NET 6 is EOL — the warning is expected and harmless on v1.9.0.
* **If the native profiler still crashes** in your environment, v1.9.0 also
  works **managed-only**: drop the three `CORECLR_*` vars and keep
  `DOTNET_STARTUP_HOOKS` + `DOTNET_ADDITIONAL_DEPS` + `DOTNET_SHARED_STORE`.
  You keep ASP.NET Core, HttpClient and ILogger instrumentation (they are
  source-based); you lose only byte-code instrumentations (e.g. `SqlClient`).
* **ECS Service Connect gotcha:** if you ever replace the collector service's
  task, **force a new deployment of the client services too** — client tasks
  wire their Service Connect proxy at start, and a client started against the
  old collector task can keep pointing at a dead endpoint while looking
  perfectly healthy.

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
and error-rate charts.

> **The metric NAMES matter.** The Coralogix APM UI queries `calls_total`,
> `duration_ms_*` and `db_calls_total` — the names the official
> `otel-integration` Helm chart produces. The spanmetrics connector's
> *default* namespace prefixes everything (`traces_span_metrics_calls_total`),
> and with those names **the APM screens stay empty even though the data is
> "in Coralogix"**. This repo's collector config sets `namespace: ""` (and
> `namespace: db` for the db connector) and copies the chart's dimension list
> verbatim (`cgx.transaction`, `http.method`, `db.*`, `service.version`, ...),
> so the APM Service Catalog gets exactly what it expects.

The metric families Coralogix receives:

| Metric | Use |
|---|---|
| `calls_total` | APM throughput + error rate |
| `duration_ms_bucket` / `_count` / `_sum` | APM latency percentiles |
| `db_calls_total`, `db_duration_ms_*` | **Database Catalog** (see below) |

**1b. Database Catalog** — DB **client** spans (here: psycopg2 auto-instrumented
Postgres calls in `hub-python`, see [`services/hub-python/app.py`](services/hub-python/app.py))
flow through a dedicated collector pipeline: `filter/db_spanmetrics` keeps only
spans carrying `db.system`, `transform/db` normalises old/new database
semantic conventions (`db.name`→`db.namespace`, `db.operation`→`db.operation.name`),
and the `spanmetrics/db` connector emits the `db_calls_total` family with the
`db.system` / `db.namespace` / `db.operation.name` / `db.collection.name`
dimensions the Database Catalog is built on.

**1c. APM Transactions** — the `coralogix` processor stamps
`cgx.transaction` / `cgx.transaction.root` onto every span, but **only if
`groupbytrace` runs immediately before it** so it sees whole traces; that
ordering comes straight from the official chart and is easy to miss.

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
