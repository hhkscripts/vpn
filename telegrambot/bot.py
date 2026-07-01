import os
import sys
import logging
import subprocess
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import List
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes, MessageHandler, filters

# Configuration
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USERS = os.getenv("TELEGRAM_ALLOWED_USERS", "")
ALLOWED_USER_IDS = [int(uid.strip()) for uid in ALLOWED_USERS.split(",") if uid.strip().isdigit()] if ALLOWED_USERS else []
BOT_HEALTH_HOST = os.getenv("BOT_HEALTH_HOST", "0.0.0.0")
BOT_HEALTH_PORT = int(os.getenv("BOT_HEALTH_PORT", "8081"))
BOT_SERVICE_NAME = "mpxhotspotbot"

# Get the directory where bot.py is located and construct the path to hotspot-manager.py
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(SCRIPT_DIR, "hotspot-manager.py")

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

_bot_ready = threading.Event()


class BotHealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/bot-health":
            self.send_response(404)
            self.end_headers()
            return

        is_ready = _bot_ready.is_set()
        payload = {
            "status": "ok" if is_ready else "down",
            "component": "telegram-bot",
            "service": BOT_SERVICE_NAME,
        }
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

        self.send_response(200 if is_ready else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        logger.debug("Bot health request: " + format, *args)


def start_bot_health_server() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((BOT_HEALTH_HOST, BOT_HEALTH_PORT), BotHealthHandler)
    thread = threading.Thread(target=server.serve_forever, name="bot-health-server", daemon=True)
    thread.start()
    logger.info("Bot health endpoint listening on %s:%s/bot-health", BOT_HEALTH_HOST, BOT_HEALTH_PORT)
    return server


def check_authorization(user_id: int) -> bool:
    if not ALLOWED_USER_IDS:
        return True # Allow all if no list provided
    return user_id in ALLOWED_USER_IDS

def run_hotspot_command(args: List[str]):
    """Run hotspot-manager.py from the host filesystem"""
    try:
        # Use the host path directly since we mount the entire filesystem
        script_path = "/host/home/hhk/Projects/vpn/telegrambot/hotspot-manager.py"
        cmd = ["python3", script_path] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        return result.stdout, result.stderr, result.returncode
    except Exception as e:
        return "", str(e), -1

async def get_status_text():
    stdout, stderr, code = run_hotspot_command(["--status", "--html"])
    if code != 0 and not stdout:
        return f"Error getting status:\n{stderr}"
    return stdout

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return

    help_text = """<b>Available Commands:</b>

<code>status</code> - Show hotspot and VPN status
<code>restart</code> - Restart hotspot services
<code>restart_vpn</code> - Restart VPN connection
<code>fix</code> - Auto-fix common issues
<code>clients</code> - Show connected clients
<code>help</code> - Show this help message

<b>Usage:</b> Send command as plain text (no / needed)"""
    
    if update.message is not None:
        await update.message.reply_text(help_text, parse_mode='HTML')

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    if update.message is not None:
        await update.message.reply_text("Welcome! Use <code>help</code> to see available commands.", parse_mode='HTML')

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    
    status_text = await get_status_text()
    
    keyboard = [[InlineKeyboardButton("Refresh", callback_data="refresh_status", icon_custom_emoji_id="6057439501377085156")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    # Check if content has changed (to avoid "Message is not modified" error)
    last_status = context.user_data.get("last_status_text") if context.user_data else None
    is_callback = update.callback_query is not None

    if is_callback and last_status == status_text:
        # Content is the same, just answer the callback without editing
        if update.callback_query is not None:
            await update.callback_query.answer("Status unchanged.")
        return

    # Save current status for next comparison
    if context.user_data is not None:
        context.user_data["last_status_text"] = status_text

    if is_callback:
        # Edit existing message if triggered by callback
        if update.callback_query is not None:
            try:
                await update.callback_query.edit_message_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')
                await update.callback_query.answer()
            except Exception as e:
                logger.warning(f"Could not edit message: {e}")
                # Fallback to sending a new message if editing fails
                cquery = update.callback_query
                # cquery သည် ဤနေရာတွင် အမြဲတမ်းရှိနေပါသည် (Refresh button နှိပ်မှ ရောက်လာသောကြောင့်)
                msg = cquery.message
                
                # msg သည် MaybeInaccessibleMessage ဖြစ်နိုင်သော်လည်း 
                # လက်တွေ့အသုံးပြုသည့်အခါ Message ဖြစ်သည်ဟု ယူဆပြီး type ignore ဖြင့် ဆက်သွားပါမည်
                if msg:
                    try:
                        await msg.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML') # type: ignore[arg-type]
                    except Exception as send_error:
                        logger.error(f"Could not send new message either: {send_error}")
    else:
        # Send new message if triggered by command
        if update.message is not None:
            await update.message.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')

async def refresh_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query is None:
        return
    try:
        await query.answer()  # Acknowledge immediately without text to avoid timeout issues
    except Exception as e:
        logger.warning(f"Could not answer callback query: {e}")
        return  # Exit if we can't acknowledge the query
    
    # Directly call status_command logic to check and update if changed
    # We pass the update directly so status_command knows it's a callback
    await status_command(update, context)

async def restart_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Restarting Hotspot...")
    stdout, stderr, _ = run_hotspot_command(["--restart"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Restart Result:\n{response}")

async def restart_vpn_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Restarting VPN...")
    stdout, stderr, _ = run_hotspot_command(["--restart-vpn"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"VPN Restart Result:\n{response}")

async def fix_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Fixing issues...")
    stdout, stderr, _ = run_hotspot_command(["--fix"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Fix Result:\n{response}")

async def clients_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return
    stdout, stderr, _ = run_hotspot_command(["--clients"])
    response = stdout if stdout else stderr
    if update.message is not None:
        await update.message.reply_text(f"Connected Clients:\n{response}")

async def handle_text_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle commands without slash (e.g., 'status' instead of '/status')"""
    if update.effective_user is None:
        return
    if not check_authorization(update.effective_user.id):
        return

    if update.message is None or update.message.text is None:
        return
    
    text = update.message.text.strip().lower()
    if text == "status":
        await status_command(update, context)
    elif text == "restart":
        await restart_command(update, context)
    elif text == "restart_vpn":
        await restart_vpn_command(update, context)
    elif text == "fix":
        await fix_command(update, context)
    elif text == "clients":
        await clients_command(update, context)
    elif text == "help":
        await help_command(update, context)

def main():
    if not BOT_TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN not found in environment variables!")
        sys.exit(1)

    health_server = start_bot_health_server()
    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("status", status_command))
    app.add_handler(CommandHandler("restart", restart_command))
    app.add_handler(CommandHandler("restart_vpn", restart_vpn_command))
    app.add_handler(CommandHandler("fix", fix_command))
    app.add_handler(CommandHandler("clients", clients_command))
    app.add_handler(CommandHandler("help", help_command))
    
    # Callback for Refresh button
    app.add_handler(CallbackQueryHandler(refresh_callback, pattern="^refresh_status$"))
    
    # Handle text messages as commands (No slash)
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text_message))

    logger.info("Bot is starting...")
    _bot_ready.set()
    try:
        app.run_polling(allowed_updates=Update.ALL_TYPES)
    finally:
        _bot_ready.clear()
        health_server.shutdown()

if __name__ == "__main__":
    main()
