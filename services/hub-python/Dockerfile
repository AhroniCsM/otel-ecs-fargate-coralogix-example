# =============================================================================
#  hub-python — Python 3.12 + OpenTelemetry AUTOMATIC instrumentation
# =============================================================================
#  Integration = 1 pip package + 1 launcher prefix. Zero application code.
# =============================================================================
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 8081

# THE ENTIRE INTEGRATION: prefix your normal start command with
# `opentelemetry-instrument`. It monkey-patches FastAPI, botocore (SQS),
# psycopg2 (RDS) and the stdlib logger at import time.
#
# CUSTOMER (AWS Lambda instead of ECS): use the ADOT Lambda layer and set
#   AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-instrument
# It is the same auto-instrumentation, just injected by the layer.
ENTRYPOINT ["opentelemetry-instrument", \
            "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8081", \
            "--no-access-log"]
