FROM python:3.11-slim

WORKDIR /app

# Install required system packages
RUN apt-get update && apt-get install -y \
    sudo \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot script
COPY bot.py .
COPY hotspot-manager.py .

# Create non-root user (optional, but recommended)
# RUN useradd -m botuser
# USER botuser

# Run the bot
CMD ["python", "bot.py"]
