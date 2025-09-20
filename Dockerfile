FROM debian:bookworm-slim

# System deps:
# - ca-certificates: TLS trust store
# - curl, unzip: to download/unpack IBKR gateway
# - nginx: reverse proxy to expose the IBKR HTTPS service
# - openjdk-17-jre-headless: Java runtime required by IBKR gateway
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Non-root user (Render-friendly)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Add this line so the template file lands in the image:
COPY nginx/app.conf /home/app/nginx/app.conf

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Ensure nginx system dirs exist and are writable by the non-root user
RUN mkdir -p /var/cache/nginx /var/run /var/log/nginx \
 && chown -R app:app /var/cache/nginx /var/run /var/log/nginx

# Run as non-root
USER app

# Render sets $PORT at runtime; expose a sane local default
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]

