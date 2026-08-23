# Tiny, uninstrumented traffic generator. ~10 MB.
FROM alpine:3.21
RUN apk add --no-cache curl
COPY loadgen.sh /loadgen.sh
RUN chmod +x /loadgen.sh
ENTRYPOINT ["/bin/sh", "/loadgen.sh"]
