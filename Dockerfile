# Dockerfile (Debian, reliable on Render)
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-lc"]

# Install dependencies: Java 17, curl/unzip/jq, nginx, net-tools for 'ss'
RUN set -euxo pipefail \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl unzip jq \
       openjdk-17-jre-headless \
       nginx net-tools \
    && rm -rf /var/lib/apt/lists/*

# Create unprivileged user and working dir
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# (Optional) expose a dummy port; Render sets $PORT at runtime anyway.
EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
