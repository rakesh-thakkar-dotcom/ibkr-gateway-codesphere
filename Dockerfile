FROM debian:bookworm-slim

# System deps:
# - ca-certificates: TLS trust store
# - curl, unzip: download/unpack IBKR gateway
# - nginx: reverse proxy
# - openjdk-17-jre-headless: Java runtime for IBKR
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Non-root user (Render-friendly)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Copy Nginx template and our non-root nginx.conf (kept under /home/app)
COPY nginx/app.conf /home/app/nginx/app.conf
COPY nginx/nginx.conf /home/app/nginx-conf/nginx.conf

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Pre-create Nginx runtime & config dirs under /home/app (created as root now) …
RUN mkdir -p \
      /home/app/nginx-conf/conf.d \
      /home/app/nginx-runtime/client_temp \
      /home/app/nginx-runtime/proxy_temp \
      /home/app/nginx-runtime/fastcgi_temp \
      /home/app/nginx-runtime/uwsgi_temp \
      /home/app/nginx-runtime/scgi_temp \
      /home/app/nginx-logs

# …then make sure EVERYTHING under /home/app is owned by user `app`
RUN chown -R app:app /home/app

# Run as non-root from here on
USER app

# Render sets $PORT at runtime; expose a sane local default
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]
