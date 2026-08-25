# Tiny, uninstrumented traffic generator.
#
# NOT alpine: musl libc's DNS resolver does not reliably resolve ECS Service
# Connect names (verified live - an Alpine-based loadgen container hung
# forever on `curl http://edge-dotnet:8080/healthz`, while a glibc-based
# container resolving the exact same Service Connect DNS name worked
# immediately). Use a small glibc-based image instead.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
COPY loadgen.sh /loadgen.sh
RUN chmod +x /loadgen.sh
ENTRYPOINT ["/bin/sh", "/loadgen.sh"]
