FROM debian:bookworm-slim

# System deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Non-root user (Render-friendly)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Nginx templates/config (kept under /home/app to avoid /etc writes)
COPY nginx/app.conf /home/app/nginx/app.conf
COPY nginx/nginx.conf /home/app/nginx-conf/nginx.conf

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create writable nginx runtime & config dirs, then hand ownership to app
RUN mkdir -p \
      /home/app/nginx-conf/conf.d \
      /home/app/nginx-runtime/client_temp \
      /home/app/nginx-runtime/proxy_temp \
      /home/app/nginx-runtime/fastcgi_temp \
      /home/app/nginx-runtime/uwsgi_temp \
      /home/app/nginx-runtime/scgi_temp \
      /home/app/nginx-logs \
 && chown -R app:app /home/app

# Drop privileges
USER app

# Render sets $PORT at runtime
EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]

