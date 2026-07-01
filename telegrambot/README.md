# Telegram Bot For GoodWifi

This optional bot controls the Raspberry Pi GoodWifi hotspot through Telegram. It runs in Docker and calls the same host manager used by the CLI:

```text
/usr/local/bin/hotspot-manager.py
```

Service/container name:

```text
mpxraspberrypibot
```

## Setup

Create a Telegram bot with `@BotFather`, then configure the bot container:

```bash
cd telegrambot
cp .env.example .env
nano .env
```

Required:

```text
TELEGRAM_BOT_TOKEN=<bot-token>
```

Optional:

```text
TELEGRAM_ALLOWED_USERS=<telegram-user-id>
BOT_HEALTH_HOST=0.0.0.0
BOT_HEALTH_PORT=8081
BOT_SERVICE_NAME=mpxraspberrypibot
```

Start or update the bot:

```bash
docker compose up -d --build
```

## Commands

| Command | Description |
| --- | --- |
| `/start` | Start the bot |
| `/status` | Show hotspot status |
| `/restart` | Restart hotspot services and reapply routing |
| `/restart_vpn` | Restart VPN and refresh GitHub routes |
| `/fix` | Run the manager's automatic fix path |
| `/clients` | Show connected client count |
| `/help` | Show command help |

## Health Endpoint

The bot exposes a health endpoint for the central Cloudflare tunnel:

```text
https://mpxraspberrypibot.hhk.my.id/bot-health
```

Cloudflare should point to:

```text
http://mpxraspberrypibot:8081
```

The central `cloudflared` container is managed outside this project. Do not run a separate `cloudflared` process from this directory.

## Troubleshooting

Check container state and logs:

```bash
docker compose ps
docker compose logs -f
```

Check the host manager directly:

```bash
sudo /usr/local/bin/hotspot-manager.py --status
```

If Telegram replies but the hotspot action fails, fix the host-side GoodWifi setup first from the main [README](../README.md).
