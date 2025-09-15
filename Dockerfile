# Dockerfile
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip jq ca-certificates \
    openjdk-17-jre-headless \
    nginx-light net-tools && \
    rm -rf /var/lib/apt/lists/*

# Create an unprivileged user (optional but good practice)
RUN useradd -m -u 1000 app
WORKDIR /home/app

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Render injects PORT at runtime; we don't choose it here.
# (Expose is optional on Render, but harmless.)
EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
