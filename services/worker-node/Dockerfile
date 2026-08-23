# =============================================================================
#  worker-node — Node.js 22 + OpenTelemetry AUTOMATIC instrumentation
# =============================================================================
#  Integration = 1 npm package + 1 environment variable (NODE_OPTIONS).
#  Zero application code.
# =============================================================================
FROM node:22-slim

WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-audit --no-fund
COPY index.js .

# THE ENTIRE INTEGRATION. `--require .../register` loads the Node SDK before
# your code, so http/undici, @aws-sdk/client-sqs and pg all get patched.
#
# Why Node for the SQS consumers?  Of the three official auto-instrumentations,
# @opentelemetry/instrumentation-aws-sdk is the one that BOTH injects the W3C
# `traceparent` into SQS MessageAttributes on send AND extracts it again on
# receive -- with no code from you. That is what stitches the producer and the
# consumer into a single trace across the queue. (See README "Async & SQS".)
ENV NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"

ENTRYPOINT ["node", "/app/index.js"]
