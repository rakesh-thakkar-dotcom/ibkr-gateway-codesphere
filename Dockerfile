FROM debian:bookworm-slim

# System deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip nginx openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Workdir
WORKDIR /opt/gateway

# Nginx config
COPY nginx/app.conf /etc/nginx/conf.d/app.conf

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Render exposes $PORT; default to 10000 for local
ENV PORT=10000
ENV GATEWAY_PORT=5000
ENV IBKR_BUNDLE_URL="https://download2.interactivebrokers.com/portal/clientportal.gw.zip"

# We run as root inside the container to avoid nginx pid/permission issues on Render
USER root

EXPOSE 10000

CMD ["/usr/local/bin/entrypoint.sh"]
