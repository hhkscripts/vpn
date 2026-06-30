# Telegram Bot for Hotspot Manager

This bot allows you to control your Raspberry Pi Hotspot via Telegram.

Service name: `mpxhotspotbot`

## Quick Start

1. Copy `.env.example` to `.env` and add your bot token.
2. Run with Docker: `docker-compose up -d --build`

## Bot Health

The Telegram bot process exposes a bot-only health endpoint:

```text
https://mpxhotspotbot.hhk.my.id/bot-health
```

For the central Cloudflare tunnel, configure the Dashboard service URL as:

```text
http://mpxhotspotbot:8081
```

For full documentation, commands, and setup details, please refer to the [Main README](../README.md).
