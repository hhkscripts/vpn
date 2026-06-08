import os
import sys
import time
import logging
import subprocess
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes, MessageHandler, filters

# Configuration
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USERS = os.getenv("TELEGRAM_ALLOWED_USERS", "")
ALLOWED_USER_IDS = [int(uid.strip()) for uid in ALLOWED_USERS.split(",") if uid.strip().isdigit()] if ALLOWED_USERS else []

# Get the directory where bot.py is located and construct the path to hotspot-manager.py
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(SCRIPT_DIR, "hotspot-manager.py")

logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

def check_authorization(user_id):
    if not ALLOWED_USER_IDS:
        return True # Allow all if no list provided
    return user_id in ALLOWED_USER_IDS

def run_hotspot_command(args):
    """Run hotspot-manager.py from the host filesystem"""
    try:
        # Use the host path directly since we mount the entire filesystem
        script_path = "/host/home/hhk/Projects/vpn/telegrambot/hotspot-manager.py"
        cmd = ["python3", script_path] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return result.stdout, result.stderr, result.returncode
    except Exception as e:
        return "", str(e), -1

async def get_status_text():
    stdout, stderr, code = run_hotspot_command(["--status", "--html"])
    if code != 0 and not stdout:
        return f"Error getting status:\n{stderr}"
    return stdout

async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
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
    
    await update.message.reply_text(help_text, parse_mode='HTML')

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id):
        await update.message.reply_text("Unauthorized access.")
        return
    await update.message.reply_text("Welcome! Use <code>help</code> to see available commands.", parse_mode='HTML')

async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id):
        return
    
    status_text = await get_status_text()
    
    keyboard = [[InlineKeyboardButton("🔄 Refresh", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    # Check if content has changed (to avoid "Message is not modified" error)
    last_status = context.user_data.get("last_status_text")
    is_callback = update.callback_query is not None

    if is_callback and last_status == status_text:
        # Content is the same, just answer the callback without editing
        await update.callback_query.answer("Status unchanged.")
        return

    # Save current status for next comparison
    context.user_data["last_status_text"] = status_text

    if is_callback:
        # Edit existing message if triggered by callback
        try:
            await update.callback_query.edit_message_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')
            await update.callback_query.answer()
        except Exception as e:
            logger.warning(f"Could not edit message: {e}")
            # Fallback to sending a new message if editing fails (e.g., message too old)
            try:
                await update.callback_query.message.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')
            except Exception as send_error:
                logger.error(f"Could not send new message either: {send_error}")
    else:
        # Send new message if triggered by command
        await update.message.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')

async def refresh_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    try:
        await query.answer()  # Acknowledge immediately without text to avoid timeout issues
    except Exception as e:
        logger.warning(f"Could not answer callback query: {e}")
        return  # Exit if we can't acknowledge the query
    
    # Directly call status_command logic to check and update if changed
    # We pass the update directly so status_command knows it's a callback
    await status_command(update, context)

async def restart_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id): return
    msg = await update.message.reply_text("Restarting Hotspot...")
    stdout, stderr, code = run_hotspot_command(["--restart"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Restart Result:\n{response}")

async def restart_vpn_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id): return
    msg = await update.message.reply_text("Restarting VPN...")
    stdout, stderr, code = run_hotspot_command(["--restart-vpn"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"VPN Restart Result:\n{response}")

async def fix_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id): return
    msg = await update.message.reply_text("Fixing issues...")
    stdout, stderr, code = run_hotspot_command(["--fix"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Fix Result:\n{response}")

async def clients_command(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not check_authorization(update.effective_user.id): return
    stdout, stderr, code = run_hotspot_command(["--clients"])
    response = stdout if stdout else stderr
    await update.message.reply_text(f"Connected Clients:\n{response}")

async def handle_text_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle commands without slash (e.g., 'status' instead of '/status')"""
    if not check_authorization(update.effective_user.id): return
    
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
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()