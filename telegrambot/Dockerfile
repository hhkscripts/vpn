FROM python:3.11-slim

# Install required system packages including sudo and network tools
RUN apt-get update && apt-get install -y \
    sudo \
    curl \
    iproute2 \
    iptables \
    hostapd \
    dnsmasq \
    wireless-tools \
    iw \
    network-manager \
    systemd \
    dnsutils \
    procps \
    kmod \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot script (not needed since we run from host, but kept for reference)
COPY bot.py .
COPY hotspot-manager.py .

# Run the bot (default, overridden by docker-compose.yml)
CMD ["python", "bot.py"]
