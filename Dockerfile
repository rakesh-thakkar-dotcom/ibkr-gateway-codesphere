# Java 17 runtime (required by the IBKR Client Portal Gateway)
FROM eclipse-temurin:17-jre-jammy

# Avoid interactive apt prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install tools needed at runtime
# - curl: to download the gateway zip
# - unzip: to extract it
# - nginx: lightweight reverse proxy (listens on $PORT and proxies to https://127.0.0.1:5000)
# - ca-certificates: ensure TLS works for curl
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip nginx ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Optional: non-root user (nginx will still work since $PORT > 1024)
RUN useradd -m -u 1000 app

WORKDIR /home/app

# Render will inject $PORT at runtime; default keeps local runs easy
ENV PORT=10000

# Copy the entrypoint script you replaced earlier
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Not required by Render, but harmless locally
EXPOSE 10000

# Start the entrypoint (downloads the gateway, starts it, then launches nginx)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
