# =============================================================================
#  edge-dotnet — .NET 8 + OpenTelemetry .NET AUTOMATIC instrumentation
# =============================================================================
#  This is the whole trick: you do NOT touch your application code or .csproj.
#  You drop the auto-instrumentation agent into the image and set a handful of
#  CLR environment variables. The CLR profiler then rewrites IL at JIT time and
#  produces spans for ASP.NET Core, HttpClient, AWS SDK, SqlClient, Npgsql, etc.
# =============================================================================

# ---------- build stage (nothing OTel-specific here) -------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY edge.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish -c Release -o /app --no-restore

# ---------- runtime stage ----------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0

# CUSTOMER: pin this. Do not use a floating version in production.
ARG OTEL_DOTNET_AUTO_VERSION=1.16.0

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
 && ls -la "${OTEL_DOTNET_AUTO_HOME}"

# 2) Turn the CLR profiler on. THESE FOUR VARS (plus OTEL_DOTNET_AUTO_HOME
#    above) ARE THE ENTIRE INTEGRATION -- exactly what the agent's own
#    `instrument.sh` exports. We set them explicitly instead of sourcing that
#    script so you can see precisely what is required.
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={918728DD-259F-4A6A-AC2B-B85E1B658318}
ENV CORECLR_PROFILER_PATH=/otel-dotnet-auto/native/OpenTelemetry.AutoInstrumentation.Native.so
ENV DOTNET_STARTUP_HOOKS=/otel-dotnet-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll

WORKDIR /app
COPY --from=build /app .

EXPOSE 8080
# No wrapper, no agent flag on the command line — the ENV above is enough.
ENTRYPOINT ["dotnet", "/app/edge.dll"]
