# =============================================================================
#  edge-dotnet — .NET 6 + OpenTelemetry .NET AUTOMATIC instrumentation
# =============================================================================
#  This is the whole trick: you do NOT touch your application code or .csproj.
#  You drop the auto-instrumentation agent into the image and set a handful of
#  CLR environment variables. The CLR profiler then rewrites IL at JIT time and
#  produces spans for ASP.NET Core, HttpClient, AWS SDK, SqlClient, Npgsql, etc.
#
#  .NET 6 vs .NET 8 — the THREE differences, all in this file only:
#    1. The agent version. v1.10.0 dropped .NET 6/7 (they are EOL), so the
#       last agent that supports .NET 6 is v1.9.0. Pin it.
#    2. Two extra environment variables: DOTNET_ADDITIONAL_DEPS and
#       DOTNET_SHARED_STORE. On .NET 6 the agent's Loader depends on
#       Microsoft.Extensions.Logging.Abstractions 8.0.0.0, which .NET 6 does
#       not ship — these two vars are how the agent injects it. Omit them and
#       the StartupHook dies with TypeInitializationException at boot.
#    3. The base image: use the `-jammy` (Ubuntu 22.04) variants, NOT the
#       default Debian 11 "bullseye" ones. Two independent reasons:
#         a. GLIBC. The v1.9.0 native profiler for linux-arm64 links against
#            glibc 2.32-2.35; bullseye has 2.31, so dlopen fails, the agent's
#            "Native profiler diagnoser" rule fails, and the agent disables
#            itself entirely — app healthy, ZERO telemetry, error only in
#            /var/log/opentelemetry/dotnet/*.log. jammy has glibc 2.35.
#            (x64 builds target an older glibc and don't hit this.)
#         b. bullseye is past EOL (Aug 2026): its apt repos have moved to
#            archive.debian.org, so even `apt-get install curl` needs a
#            sources.list workaround. Ubuntu jammy is supported until 2027.
#  Application code and csproj: ZERO changes (only TargetFramework=net6.0).
# =============================================================================

# ---------- build stage (nothing OTel-specific here) -------------------------
FROM mcr.microsoft.com/dotnet/sdk:6.0-jammy AS build
WORKDIR /src
COPY edge.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish -c Release -o /app --no-restore

# ---------- runtime stage ----------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:6.0-jammy

# CUSTOMER: pin this. v1.9.0 is the LAST version that supports .NET 6/7
# (v1.10.0 removed them after their end of support). On .NET 8+ use the
# latest agent instead.
ARG OTEL_DOTNET_AUTO_VERSION=1.9.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 1) Download + unpack the auto-instrumentation agent into /otel-dotnet-auto.
#    The install script picks the correct native build for the image arch
#    (linux-x64 / linux-arm64 / musl variants) automatically.
ENV OTEL_DOTNET_AUTO_HOME=/otel-dotnet-auto
RUN curl -sSfL "https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases/download/v${OTEL_DOTNET_AUTO_VERSION}/otel-dotnet-auto-install.sh" -o /tmp/otel-install.sh \
 && sh /tmp/otel-install.sh \
 && rm /tmp/otel-install.sh \
 # Normalise the arch-specific native dir to a stable name so the ENV below
 # works on both x86_64 and arm64 hosts.
 && ln -s "${OTEL_DOTNET_AUTO_HOME}/$(uname -m | sed -e 's/^x86_64$/linux-x64/' -e 's/^aarch64$/linux-arm64/')" "${OTEL_DOTNET_AUTO_HOME}/native" \
 # Fail the BUILD if the native profiler can't load on this base image
 # (glibc/arch mismatch) instead of silently shipping a non-instrumented app.
 && ldd "${OTEL_DOTNET_AUTO_HOME}/native/OpenTelemetry.AutoInstrumentation.Native.so" >/dev/null \
 && ls -la "${OTEL_DOTNET_AUTO_HOME}"

# 2) Turn the CLR profiler on. THESE SIX VARS (plus OTEL_DOTNET_AUTO_HOME
#    above) ARE THE ENTIRE INTEGRATION -- exactly what the v1.9.0 agent's own
#    `instrument.sh` exports. We set them explicitly instead of sourcing that
#    script so you can see precisely what is required.
#
#    If the native profiler cannot work in your environment (exotic base
#    image, SIGSEGV at startup), you can drop the three CORECLR_* lines and
#    keep the rest: ASP.NET Core, HttpClient and ILogger instrumentation are
#    source-based and still work; you lose only byte-code instrumentations
#    (SqlClient and friends).
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/native/OpenTelemetry.AutoInstrumentation.Native.so
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
# .NET 6 ONLY (agent <= v1.9.0): inject the agent's updated framework
# assemblies. Without these two, the startup hook throws
# TypeInitializationException (missing Microsoft.Extensions.Logging.Abstractions
# 8.0.0.0) at boot.
ENV DOTNET_ADDITIONAL_DEPS=/otel-dotnet-auto/AdditionalDeps
ENV DOTNET_SHARED_STORE=/otel-dotnet-auto/store

WORKDIR /app
COPY --from=build /app .

EXPOSE 8080
# No wrapper, no agent flag on the command line — the ENV above is enough.
ENTRYPOINT ["dotnet", "/app/edge.dll"]
