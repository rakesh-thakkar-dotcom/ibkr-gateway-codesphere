# Minimal Debian + Nginx + tools we need
FROM debian:bookworm-slim

# Install runtime deps: curl (download zip), unzip (extract), nginx (reverse proxy)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx \
 && rm -rf /var/lib/apt/lists/*

# Non-root user (Render is fine with high port)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run as non-root; Nginx will listen on high port ($PORT), so this is fine
USER app

# Render injects $PORT; we expose a default for sanity when running locally
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]
