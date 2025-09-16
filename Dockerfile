FROM debian:bookworm-slim

# curl (download ZIP), unzip (extract), nginx (reverse proxy)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as non-root; Nginx will listen on high port ($PORT)
USER app

# Default for local runs (Render sets $PORT for us)
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]

