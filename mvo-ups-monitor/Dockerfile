FROM alpine:3.20
RUN apk add --no-cache bash util-linux coreutils python3
COPY watch.sh /app/watch.sh
COPY entrypoint.sh /app/entrypoint.sh
COPY server.py /app/server.py
RUN chmod +x /app/watch.sh /app/entrypoint.sh /app/server.py
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]
