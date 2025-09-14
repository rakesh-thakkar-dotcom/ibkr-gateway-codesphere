# Use an official OpenJDK runtime as base
FROM openjdk:17-jdk-slim

# Install required tools
RUN apt-get update && apt-get install -y curl unzip && rm -rf /var/lib/apt/lists/*

# Set environment variables
ENV APP_HOME=/home/app/ibgateway
WORKDIR $APP_HOME

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose the IBKR Gateway default port
EXPOSE 5000

# Start the entrypoint
CMD ["/usr/local/bin/entrypoint.sh"]
