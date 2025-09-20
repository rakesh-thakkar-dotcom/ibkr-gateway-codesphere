# ---- Base image ----
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

# ---- Non-root user (Render-friendly) ----
RUN useradd -m -u 1000 app
WORKDIR /home/app

# ---- Copy Nginx configs ----
# TEMPLATE stays in /home/app so entrypoint can substitute PORTs at runtime.
COPY nginx/app.conf /home/app/nginx/app.conf
# This replaces the default Nginx config to use app-owned dirs (pid/temp).
COPY nginx/nginx.conf /etc/nginx/nginx.conf

# ---- Entrypoint ----
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ---- Ensure all Nginx runtime paths exist and are app-writable ----
RUN mkdir -p \
      /var/cache/nginx/client_temp \
      /var/cache/nginx/proxy_temp \
      /var/cache/nginx/fastcgi_temp \
      /var/cache/nginx/uwsgi_temp \
      /var/cache/nginx/scgi_temp \
      /var/run/nginx \
      /var/log/nginx \
      /etc/nginx/conf.d \
      /var/lib/nginx \
 && chown -R app:app /var/cache/nginx /var/run /var/log/nginx /etc/nginx /var/lib/nginx

# ---- Run as non-root ----
USER app

# Render sets $PORT at runtime; expose a sane local default
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]


