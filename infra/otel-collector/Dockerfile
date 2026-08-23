# =============================================================================
#  Coralogix Distribution for OpenTelemetry (CDOT) with our config baked in.
# =============================================================================
#  The upstream image has no default config, so we COPY ours and point the
#  collector at it. Baking the config keeps the ECS task definition trivial.
#
#  Alternative (what the Coralogix CloudFormation template does): keep the
#  config in S3 and pass --config=s3://... . Baking it means the config is
#  version-controlled next to the code, which is nicer for a POC.
# =============================================================================
FROM coralogixrepo/coralogix-otel-collector:v0.5.13

COPY otel-config.yaml /etc/cdot/config.yaml

EXPOSE 4317 4318 8888 13133
CMD ["--config=file:/etc/cdot/config.yaml"]
