FROM debian:bookworm-slim

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd -m -u 1000 app
WORKDIR /home/app

# App files
COPY nginx/app.conf /home/app/nginx/app.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# User-writable nginx dirs
RUN mkdir -p \
      /home/app/nginx-conf/conf.d \
      /home/app/nginx-runtime/client_temp \
      /home/app/nginx-runtime/proxy_temp \
      /home/app/nginx-runtime/fastcgi_temp \
      /home/app/nginx-runtime/uwsgi_temp \
      /home/app/nginx-runtime/scgi_temp \
      /home/app/nginx-logs \
 && chown -R app:app /home/app

USER app
EXPOSE 10000
CMD ["/usr/local/bin/entrypoint.sh"]

