# Small base with Java + tools to fetch the gateway
FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl unzip ca-certificates openjdk-17-jre-headless \
 && rm -rf /var/lib/apt/lists/*

ENV DEST=/opt/ibgateway
WORKDIR ${DEST}

# Start script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# IBKR Client Portal Gateway listens on 5000
EXPOSE 5000

CMD ["/entrypoint.sh"]
