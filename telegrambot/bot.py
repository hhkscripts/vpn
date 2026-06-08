#!/usr/bin/env python3
"""
Telegram Bot for Raspberry Pi Hotspot Control
Controls hotspot-manager.py via Telegram commands
"""

import os
import subprocess
import logging
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application,
    CommandHandler,
    CallbackQueryHandler,
    ContextTypes,
)

# Logging setup
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# Allowed user IDs (optional security measure)
ALLOWED_USERS = os.getenv("TELEGRAM_ALLOWED_USERS", "").split(",")


def is_authorized(user_id: int) -> bool:
    """Check if user is authorized to use the bot."""
    if not ALLOWED_USERS or ALLOWED_USERS == [""]:
        return True  # No restriction if not configured
    return str(user_id) in ALLOWED_USERS


def run_hotspot_command(args: list[str]) -> tuple[bool, str]:
    """Run hotspot-manager.py command and return result."""
    cmd = ["sudo", "/usr/local/bin/hotspot-manager.py"] + args
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=60, check=False
        )
        output = result.stdout.strip()
        if result.stderr:
            output += "\n" + result.stderr.strip()
        return result.returncode == 0, output
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, f"Error: {str(e)}"


def format_status_message(status_output: str) -> str:
    """Format status output for Telegram message."""
    # Remove ANSI color codes
    import re

    ansi_escape = re.compile(r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
    clean_output = ansi_escape.sub("", status_output)
    return f"```\n{clean_output}\n```"


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Send welcome message."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    welcome_text = """
👋 Welcome to Raspberry Pi Hotspot Control Bot!

Available commands:
/status - Check hotspot status
/restart - Restart hotspot services
/restart_vpn - Restart VPN connection
/fix - Fix hotspot issues
/clients - Show connected clients
/help - Show this help message

Use /status with the refresh button to update status without new messages.
    """
    await update.message.reply_text(welcome_text)


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Show help message."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    await start(update, context)


async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Get hotspot status with refresh button."""
    if not is_authorized(update.effective_user.id):
        if update.callback_query:
            await update.callback_query.answer("⛔ Not authorized", show_alert=True)
            return
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    # Run status command
    success, output = run_hotspot_command(["--status"])

    if not success:
        message_text = f"❌ Error getting status:\n```\n{output}\n```"
    else:
        message_text = format_status_message(output)

    # Create keyboard with refresh button
    keyboard = [[InlineKeyboardButton("🔄 Refresh", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    if update.callback_query:
        # Edit existing message
        try:
            await update.callback_query.edit_message_text(
                text=message_text,
                parse_mode="Markdown",
                reply_markup=reply_markup,
            )
            await update.callback_query.answer("Status updated ✅")
        except Exception as e:
            logger.error(f"Error editing message: {e}")
            # If edit fails (message too old), send new message
            await context.bot.send_message(
                chat_id=update.callback_query.message.chat_id,
                text=message_text,
                parse_mode="Markdown",
                reply_markup=reply_markup,
            )
    else:
        # Send new message
        await update.message.reply_text(
            text=message_text,
            parse_mode="Markdown",
            reply_markup=reply_markup,
        )


async def refresh_status_callback(
    update: Update, context: ContextTypes.DEFAULT_TYPE
) -> None:
    """Handle refresh button callback."""
    await status(update, context)


async def restart(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Restart hotspot services."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    await update.message.reply_text("🔄 Restarting hotspot services...")
    success, output = run_hotspot_command(["--restart"])

    if success:
        response = "✅ Hotspot services restarted successfully!\n\n"
        # Get status after restart
        _, status_output = run_hotspot_command(["--status"])
        response += format_status_message(status_output)
    else:
        response = f"❌ Error restarting services:\n```\n{output}\n```"

    keyboard = [[InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        text=response, parse_mode="Markdown", reply_markup=reply_markup
    )


async def restart_vpn(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Restart VPN connection."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    await update.message.reply_text("🔄 Restarting VPN connection...")
    success, output = run_hotspot_command(["--restart-vpn"])

    if success:
        response = "✅ VPN connection restarted successfully!"
    else:
        response = f"❌ Error restarting VPN:\n```\n{output}\n```"

    keyboard = [[InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        text=response, parse_mode="Markdown", reply_markup=reply_markup
    )


async def fix(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Fix hotspot issues."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    await update.message.reply_text("🔧 Fixing hotspot issues...")
    success, output = run_hotspot_command(["--fix"])

    if success:
        response = "✅ Hotspot fixed successfully!\n\n"
        response += format_status_message(output)
    else:
        response = f"❌ Error fixing hotspot:\n```\n{output}\n```"

    keyboard = [[InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        text=response, parse_mode="Markdown", reply_markup=reply_markup
    )


async def clients(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Show connected clients."""
    if not is_authorized(update.effective_user.id):
        await update.message.reply_text("⛔ You are not authorized to use this bot.")
        return

    success, output = run_hotspot_command(["--clients"])

    if success:
        response = f"📱 Connected Clients:\n```\n{output}\n```"
    else:
        response = f"❌ Error getting clients:\n```\n{output}\n```"

    keyboard = [[InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    await update.message.reply_text(
        text=response, parse_mode="Markdown", reply_markup=reply_markup
    )


async def error_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Log errors."""
    logger.error(f"Update {update} caused error: {context.error}")


def main() -> None:
    """Start the bot."""
    token = os.getenv("TELEGRAM_BOT_TOKEN")
    if not token:
        logger.error("TELEGRAM_BOT_TOKEN environment variable not set!")
        return

    # Create application
    application = Application.builder().token(token).build()

    # Add handlers
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CommandHandler("status", status))
    application.add_handler(CommandHandler("restart", restart))
    application.add_handler(CommandHandler("restart_vpn", restart_vpn))
    application.add_handler(CommandHandler("fix", fix))
    application.add_handler(CommandHandler("clients", clients))

    # Add callback handler for refresh button
    application.add_handler(
        CallbackQueryHandler(refresh_status_callback, pattern="^refresh_status$")
    )

    # Add error handler
    application.add_error_handler(error_handler)

    # Start the bot
    logger.info("Starting Telegram Bot...")
    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
