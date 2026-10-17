# Base image pinned by multi-arch index digest (alpine 3.20.10 at pin time).
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN apk add --no-cache bash util-linux coreutils python3
COPY watch.sh /app/watch.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY server.py /app/server.py
RUN chmod +x /app/watch.sh /app/entrypoint.sh /app/server.py
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
