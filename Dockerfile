# Simple image to run IBKR Client Portal Gateway on port 5000
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /opt/ibkr

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl unzip ca-certificates openjdk-11-jre-headless \
 && rm -rf /var/lib/apt/lists/*

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose gateway port
EXPOSE 5000

# Run the entrypoint (downloads and launches the gateway)
CMD ["/entrypoint.sh"]
