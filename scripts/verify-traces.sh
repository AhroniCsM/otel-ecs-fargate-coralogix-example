#!/usr/bin/env bash
# =============================================================================
#  Prove the telemetry is arriving, straight from the terminal, with cx-cli.
#  Install: brew install coralogix/tap/cx   (then: cx profiles add)
# =============================================================================
set -uo pipefail

P="${CX_PROFILE:-aharon-test}"       # CUSTOMER: your cx-cli profile name
APP="${CX_APP:-moh-hub-poc}"         # = service.namespace from OTEL_RESOURCE_ATTRIBUTES
WINDOW="${WINDOW:-now-15m}"

run () { echo; echo "### $1"; shift; cx -p "$P" "$@"; }

run "1. Which services are reporting, and how many spans each?" \
  spans "filter \$l.applicationName == '$APP' | groupby \$l.serviceName agg count() as spans | sortby spans desc" \
  --start "$WINDOW" -o agents

run "2. Every operation seen (should include the SQS send)" \
  spans "filter \$l.applicationName == '$APP' | groupby \$l.serviceName, \$l.operationName agg count() as n | sortby n desc | limit 40" \
  --start "$WINDOW" -o agents

run "3. THE CORRELATION ANSWER: business GUID promoted onto the spans" \
  spans "filter \$l.applicationName == '$APP' && \$d.tags['hub.message_id'] != null | choose \$l.serviceName, \$l.operationName, \$d.tags['hub.message_id'] as hub_message_id, \$d.traceID | limit 10" \
  --start "$WINDOW" -o agents

run "4. Confirm the ECS resource attributes the collector added" \
  spans "filter \$l.applicationName == '$APP' | choose \$d.process.tags['cloud.platform'] as platform, \$d.process.tags['aws.ecs.cluster.arn'] as cluster, \$d.process.tags['host.arch'] as arch | limit 2" \
  --start "$WINDOW" -o agents

# NOTE: Coralogix flattens dots in LOG attribute keys, so the span attribute
# `hub.message_id` is queried as `hub_message_id` on the logs side. On SPANS the
# dotted form works ($d.tags['hub.message_id']).
run "5. Logs carry the same GUID + trace id (log -> trace pivot)" \
  logs "filter \$l.applicationname == '$APP' && \$d.attributes['hub_message_id'] != null | choose \$l.subsystemname as svc, \$d.attributes['hub_message_id'] as hub_message_id, \$d.attributes['otelTraceID'] as trace_id, \$d.body as body | limit 5" \
  --start "$WINDOW" -o agents

run "6. APM RED metrics derived from the spans (span metrics connector)" \
  metrics query "sum by (service_name) (increase(traces_span_metrics_calls_total{service_name=~'edge-dotnet|hub-python'}[10m]))" \
  -o agents

run "7. Environment facet (deployment.environment.name)" \
  spans "filter \$l.applicationName == '$APP' | groupby \$d.process.tags['deployment.environment.name'] as env agg count() as spans" \
  --start "$WINDOW" -o agents

echo
echo "### To trace ONE transaction end to end, take a hub_message_id from step 3:"
echo "cx -p $P spans \"filter \\\$d.tags['hub.message_id'] == '<GUID>' | choose \\\$l.serviceName, \\\$l.operationName, \\\$d.traceID\" --start $WINDOW -o agents"
