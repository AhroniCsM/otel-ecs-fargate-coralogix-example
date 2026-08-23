// =============================================================================
//  edge-dotnet  —  Ministry of Health "HUB" edge service
// =============================================================================
//  WHAT THIS STANDS IN FOR IN YOUR ARCHITECTURE
//  --------------------------------------------
//   BLUE flow (clinic -> MoH):   AWS ALB  ->  API Gateway  ->  (routing Lambda)
//       POST /api/v1/hub/messages     <-- the clinic calls this
//
//   GREEN flow (MoH -> clinic):  (green dispatch Lambda) -> F5 API GW -> clinic
//       POST /f5/clinic-callback      <-- the green worker calls this
//
//  >>> CUSTOMER: THIS FILE CONTAINS ZERO OPENTELEMETRY CODE. <<<
//  No `using OpenTelemetry`, no TracerProvider, no ActivitySource, no manual
//  spans. Every span you will see in Coralogix is produced by the OpenTelemetry
//  .NET automatic instrumentation agent, which is wired up entirely through the
//  Dockerfile + environment variables. See Dockerfile and README.md.
//
//  The ONLY thing this app does "on purpose" for observability is pass the
//  business correlation GUID (hub_message_id) along as a query-string value and
//  an HTTP header. That is a *business* requirement, not an OTel requirement --
//  it is what lets you join the async BLUE trace to the async GREEN trace.
// =============================================================================

using System.Text;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHttpClient();

// Log to stdout as JSON-ish; the OTel auto-instrumentation also ships ILogger
// records to Coralogix over OTLP (OTEL_LOGS_EXPORTER=otlp) *with trace_id
// automatically attached*, which is how you pivot log -> trace.
builder.Logging.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss "; });

var app = builder.Build();

// -----------------------------------------------------------------------------
// CUSTOMER: EDIT HERE.
// In the real system this is the private DNS of your routing Lambda / internal
// API Gateway. In this demo everything runs on one ECS-EC2 host with
// networkMode=host, so services reach each other over localhost.
// -----------------------------------------------------------------------------
var hubRouterUrl = Environment.GetEnvironmentVariable("HUB_ROUTER_URL") ?? "http://localhost:8081";

static string GetHubMessageId(HttpRequest req)
{
    // The GUID may arrive as a query param or as a header. We accept both.
    var fromQuery = req.Query["hub_message_id"].ToString();
    if (!string.IsNullOrEmpty(fromQuery)) return fromQuery;
    if (req.Headers.TryGetValue("x-hub-message-id", out var h)) return h.ToString();
    return Guid.NewGuid().ToString();
}

// =============================================================================
//  BLUE FLOW  —  step 1 of 5
//  clinic  --HTTP-->  [ALB + API GW : this endpoint]  --HTTP-->  hub-python
// =============================================================================
app.MapPost("/api/v1/hub/messages", async (HttpRequest req, IHttpClientFactory factory,
                                           ILogger<Program> log) =>
{
    var hubMessageId = GetHubMessageId(req);
    using var reader = new StreamReader(req.Body);
    var body = await reader.ReadToEndAsync();
    if (string.IsNullOrWhiteSpace(body)) body = "{}";

    // Structured log: `hub_message_id` becomes a log ATTRIBUTE (not just text),
    // and the auto-instrumentation stamps trace_id/span_id onto this record.
    log.LogInformation("BLUE 1/5 edge received clinic request hub_message_id={hub_message_id}",
                       hubMessageId);

    var client = factory.CreateClient();
    client.Timeout = TimeSpan.FromSeconds(15);

    // HttpClient is auto-instrumented -> it emits a CLIENT span AND injects the
    // W3C `traceparent` header for us. hub-python therefore CONTINUES the same
    // trace. Nothing to code.
    var content = new StringContent(body, Encoding.UTF8, "application/json");
    content.Headers.Add("x-hub-message-id", hubMessageId);

    var url = $"{hubRouterUrl}/process?hub_message_id={Uri.EscapeDataString(hubMessageId)}";
    var resp = await client.PostAsync(url, content);
    var downstream = await resp.Content.ReadAsStringAsync();

    return Results.Json(new
    {
        accepted = true,
        hub_message_id = hubMessageId,
        downstream_status = (int)resp.StatusCode,
        downstream = downstream
    });
});

// =============================================================================
//  GREEN FLOW  —  step 5 of 5  (the async "answer" coming back to the clinic)
//  worker-node  --HTTP-->  [F5 API GW : this endpoint]  -->  outpatient clinic
// =============================================================================
app.MapPost("/f5/clinic-callback", async (HttpRequest req, ILogger<Program> log) =>
{
    var hubMessageId = GetHubMessageId(req);
    using var reader = new StreamReader(req.Body);
    var body = await reader.ReadToEndAsync();

    log.LogInformation("GREEN 5/5 F5 API GW delivered approval to clinic hub_message_id={hub_message_id}",
                       hubMessageId);

    // Pretend to hand off to the clinic's Agent. Simulate a little work so the
    // span has a realistic duration.
    await Task.Delay(Random.Shared.Next(5, 40));

    return Results.Json(new { delivered_to_clinic = true, hub_message_id = hubMessageId });
});

app.MapGet("/healthz", () => Results.Text("ok"));

app.Run("http://0.0.0.0:8080");
