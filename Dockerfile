FROM debian:bookworm-slim

# System deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Non-root user (Render-friendly)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Ship our nginx templates/config into writable locations (owned by app)
COPY nginx/app.conf /home/app/nginx/app.conf
# Minimal nginx.conf that runs fully under /home/app
RUN mkdir -p /home/app/nginx-conf
RUN printf '%s\n' \
'worker_processes auto;' \
'pid /home/app/nginx-runtime/nginx.pid;' \
'events { worker_connections 1024; }' \
'http {' \
'  map $http_upgrade $connection_upgrade { default upgrade; "" close; }' \
'  absolute_redirect off; server_name_in_redirect off; port_in_redirect off;' \
'  log_format main '\''$remote_addr - $remote_user [$time_local] "$request" '\'''\''$status $body_bytes_sent "$http_referer" '\'''\''"$http_user_agent" "$http_x_forwarded_for"'\'';' \
'  access_log /dev/stdout main; error_log /dev/stderr warn;' \
'  sendfile on; tcp_nopush on; types_hash_max_size 4096;' \
'  include /etc/nginx/mime.types; default_type application/octet-stream;' \
'  client_header_buffer_size 16k; large_client_header_buffers 8 64k;' \
'  client_body_temp_path  /home/app/nginx-runtime/client_temp;' \
'  proxy_temp_path        /home/app/nginx-runtime/proxy_temp;' \
'  fastcgi_temp_path      /home/app/nginx-runtime/fastcgi_temp;' \
'  uwsgi_temp_path        /home/app/nginx-runtime/uwsgi_temp;' \
'  scgi_temp_path         /home/app/nginx-runtime/scgi_temp;' \
'  proxy_buffering off;' \
'  include /home/app/nginx-conf/conf.d/*.conf;' \
'}' \
> /home/app/nginx-conf/nginx.conf

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create writable nginx runtime & config dirs
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

