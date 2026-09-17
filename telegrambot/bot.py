import asyncio
import re
import os
import sys
import logging
import subprocess
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import List
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReplyKeyboardMarkup, KeyboardButton
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes, MessageHandler, filters

# Configuration
BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ALLOWED_USERS = os.getenv("TELEGRAM_ALLOWED_USERS", "")
ALLOWED_USER_IDS = [int(uid.strip()) for uid in ALLOWED_USERS.split(",") if uid.strip().isdigit()] if ALLOWED_USERS else []
BOT_HEALTH_HOST = os.getenv("BOT_HEALTH_HOST", "0.0.0.0")
BOT_HEALTH_PORT = int(os.getenv("BOT_HEALTH_PORT", "8081"))
BOT_SERVICE_NAME = os.getenv("BOT_SERVICE_NAME", "mpxraspberrypibot")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(SCRIPT_DIR, "hotspot-manager.py")


# Premium Custom Emoji IDs
EMOJI_STATS = "6143449494244563627"     # 📶 / 📊 Stats
EMOJI_CLIENTS = "6127157759872868272"   # 📡 Signal / Clients
EMOJI_REFRESH = "6057439501377085156"   # 🔄 Refresh / Restart
EMOJI_LOCK = "6059947491695008618"      # 🔒 Lock / VPN
EMOJI_TOOLS = "6141134446742478627"     # 🔧 Tools / Fix
EMOJI_HELP = "6307322000033458270"      # 📔 Book / Help

MAIN_KEYBOARD = ReplyKeyboardMarkup(
    [
        [
            KeyboardButton("Status", icon_custom_emoji_id=EMOJI_STATS),
            KeyboardButton("Clients", icon_custom_emoji_id=EMOJI_CLIENTS),
        ],
        [
            KeyboardButton("Restart", icon_custom_emoji_id=EMOJI_REFRESH),
            KeyboardButton("Restart VPN", icon_custom_emoji_id=EMOJI_LOCK),
        ],
        [
            KeyboardButton("Fix", icon_custom_emoji_id=EMOJI_TOOLS),
            KeyboardButton("Switch VPN", icon_custom_emoji_id=EMOJI_REFRESH),
        ],
        [
            KeyboardButton("IPv6 Mode", icon_custom_emoji_id=EMOJI_TOOLS),
            KeyboardButton("Help", icon_custom_emoji_id=EMOJI_HELP),
        ],
    ],
    resize_keyboard=True,
    is_persistent=False,
)


logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.WARNING)
logger = logging.getLogger(__name__)
for noisy_logger in ("httpx", "httpcore", "telegram", "telegram.ext"):
    logging.getLogger(noisy_logger).setLevel(logging.WARNING)

_bot_ready = threading.Event()


class BotHealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/bot-health":
            self.send_response(404)
            self.end_headers()
            return

        if _bot_ready.is_set():
            payload = json.dumps({"status": "ok", "service": BOT_SERVICE_NAME}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        payload = json.dumps({"status": "starting", "service": BOT_SERVICE_NAME}).encode("utf-8")
        self.send_response(503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        return


def start_bot_health_server() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((BOT_HEALTH_HOST, BOT_HEALTH_PORT), BotHealthHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    return server


def check_authorization(user_id: int) -> bool:
    if not ALLOWED_USER_IDS:
        return True
    return user_id in ALLOWED_USER_IDS


def run_hotspot_command(args: List[str]):
    """Run hotspot-manager.py in the host namespaces."""
    try:
        script_path = "/home/hhk/Projects/vpn/telegrambot/hotspot-manager.py"
        cmd = [
            "nsenter",
            "--target",
            "1",
            "--mount",
            "--uts",
            "--ipc",
            "--net",
            "--pid",
            "--",
            "python3",
            script_path,
        ] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        return result.stdout, result.stderr, result.returncode
    except Exception as e:
        return "", str(e), -1


async def get_status_text() -> str:
    stdout, stderr, code = run_hotspot_command(["--status", "--html"])
    if code != 0 and not stdout:
        return f"Error getting status:\n{stderr}"
    return stdout if stdout else "No output from hotspot manager."


def make_status_keyboard(status_text: str) -> InlineKeyboardMarkup:
    if "awg0" in status_text or "AmneziaWG" in status_text:
        switch_btn = InlineKeyboardButton(
            "Switch to OpenVPN (tun0)",
            callback_data="switch_tun0",
            icon_custom_emoji_id=EMOJI_REFRESH,
        )
    else:
        switch_btn = InlineKeyboardButton(
            "Switch to AmneziaWG (awg0)",
            callback_data="switch_awg0",
            icon_custom_emoji_id=EMOJI_LOCK,
        )

    ipv6_btn = InlineKeyboardButton(
        "🛡 IPv6 Mode",
        callback_data="menu_ipv6",
        icon_custom_emoji_id=EMOJI_TOOLS,
    )
    refresh_btn = InlineKeyboardButton(
        "Refresh",
        callback_data="refresh_status",
        icon_custom_emoji_id=EMOJI_REFRESH,
    )
    return InlineKeyboardMarkup([[switch_btn], [ipv6_btn, refresh_btn]])


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    help_text = """<b>Available Commands:</b>

<code>status</code> - Show hotspot and VPN status
<code>switch_vpn &lt;awg0|tun0|auto&gt;</code> - Switch active VPN backend
<code>ipv6 &lt;drop|reject|off&gt;</code> - Configure IPv6 leak protection
<code>restart</code> - Restart hotspot services
<code>restart_vpn</code> - Restart VPN connection
<code>fix</code> - Auto-fix common issues
<code>clients</code> - Show connected clients
<code>help</code> - Show this help message

<b>Usage:</b> Send command as plain text (no / needed)"""

    if update.message is not None:
        await update.message.reply_text(help_text, reply_markup=MAIN_KEYBOARD, parse_mode='HTML')


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    await help_command(update, context)


async def status_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)

    if update.message is not None:
        if context.user_data is not None and not context.user_data.get("keyboard_set"):
            context.user_data["keyboard_set"] = True
            await update.message.reply_text("GoodWifi Hotspot Manager", reply_markup=MAIN_KEYBOARD)
        await update.message.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')


async def refresh_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query is None:
        return
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        try:
            await query.answer("Unauthorized", show_alert=True)
        except Exception:
            pass
        return

    try:
        await query.answer("Refreshing...")
    except Exception:
        pass

    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)

    try:
        await query.edit_message_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')
    except Exception as e:
        if "not modified" not in str(e).lower():
            logger.warning(f"Could not edit message: {e}")


def get_current_backend_name() -> str:
    conf_path = "/host/etc/goodwifi/goodwifi.conf"
    if not os.path.exists(conf_path):
        conf_path = "/etc/goodwifi/goodwifi.conf"
    backend = "auto"
    if os.path.exists(conf_path):
        try:
            with open(conf_path, "r") as f:
                for line in f:
                    if line.startswith("VPN_BACKEND="):
                        backend = line.split("=", 1)[1].strip().strip('"').strip("'")
        except Exception:
            pass
    names = {
        "awg0": "AmneziaWG (awg0)",
        "tun0": "OpenVPN (tun0)",
        "wg0": "WireGuard (wg0)",
        "auto": "Auto",
    }
    return names.get(backend, backend)


def get_current_ipv6_mode() -> str:
    conf_path = "/host/etc/goodwifi/goodwifi.conf"
    if not os.path.exists(conf_path):
        conf_path = "/etc/goodwifi/goodwifi.conf"

    if os.path.exists(conf_path):
        try:
            with open(conf_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("IPV6_LEAK_PROTECTION="):
                        val = (
                            line.split("=", 1)[1]
                            .strip()
                            .strip('"')
                            .strip("'")
                            .lower()
                        )
                        if val in ["drop", "reject", "off"]:
                            return val
        except Exception:
            pass
    return "drop"


async def ipv6_menu_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    current = get_current_ipv6_mode().upper()
    keyboard = [
        [
            InlineKeyboardButton("🔴 Drop (Default)", callback_data="ipv6_drop"),
            InlineKeyboardButton("🟡 Reject (Fast)", callback_data="ipv6_reject"),
        ],
        [
            InlineKeyboardButton("⚪ Off (Allow IPv6)", callback_data="ipv6_off"),
        ],
        [
            InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status"),
        ],
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    text = (
        f"<b>🛡 IPv6 Leak Protection:</b>\n\n"
        f"Current Mode: <code>{current}</code>\n\n"
        f"• <b>Drop</b>: Silently drop client IPv6 packets (Recommended)\n"
        f"• <b>Reject</b>: Reject with ICMPv6 unreachable (Fail fast)\n"
        f"• <b>Off</b>: Disable IPv6 blocking (Allow IPv6)\n\n"
        f"Choose an option below to set:"
    )
    if update.message:
        await update.message.reply_text(text, reply_markup=reply_markup, parse_mode='HTML')


async def ipv6_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query is None or query.data is None:
        return
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        try:
            await query.answer("Unauthorized", show_alert=True)
        except Exception:
            pass
        return

    if query.data == "menu_ipv6":
        current = get_current_ipv6_mode().upper()
        keyboard = [
            [
                InlineKeyboardButton("🔴 Drop (Default)", callback_data="ipv6_drop"),
                InlineKeyboardButton("🟡 Reject (Fast)", callback_data="ipv6_reject"),
            ],
            [
                InlineKeyboardButton("⚪ Off (Allow IPv6)", callback_data="ipv6_off"),
            ],
            [
                InlineKeyboardButton("🔄 Refresh Status", callback_data="refresh_status"),
            ],
        ]
        text = (
            f"<b>🛡 IPv6 Leak Protection:</b>\n\n"
            f"Current Mode: <code>{current}</code>\n\n"
            f"• <b>Drop</b>: Silently drop client IPv6 packets (Recommended)\n"
            f"• <b>Reject</b>: Reject with ICMPv6 unreachable (Fail fast)\n"
            f"• <b>Off</b>: Disable IPv6 blocking (Allow IPv6)\n\n"
            f"Choose an option below to set:"
        )
        try:
            await query.edit_message_text(text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode='HTML')
        except Exception:
            pass
        return

    mode = query.data.replace("ipv6_", "")
    try:
        await query.answer(f"Setting IPv6 protection to {mode.upper()}...")
    except Exception:
        pass

    run_hotspot_command(["--set-ipv6", mode])
    await asyncio.sleep(1)
    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)

    try:
        await query.edit_message_text(
            text=f"<b>IPv6 Protection updated to {mode.upper()}!</b>\n\n{status_text}",
            reply_markup=reply_markup,
            parse_mode='HTML',
        )
    except Exception as e:
        if "not modified" not in str(e).lower():
            logger.warning(f"Could not edit message after ipv6 switch: {e}")


async def ipv6_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    target = context.args[0].lower() if context.args else None
    if not target or target not in ["drop", "reject", "off"]:
        await ipv6_menu_command(update, context)
        return

    run_hotspot_command(["--set-ipv6", target])
    await asyncio.sleep(1)
    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)
    if update.message:
        await update.message.reply_text(
            f"<b>IPv6 Protection set to {target.upper()}!</b>\n\n{status_text}",
            reply_markup=reply_markup,
            parse_mode='HTML',
        )


async def switch_menu_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    current = get_current_backend_name()
    keyboard = [
        [
            InlineKeyboardButton("⚡ AmneziaWG (awg0)", callback_data="switch_awg0", icon_custom_emoji_id=EMOJI_LOCK),
            InlineKeyboardButton("🛡 OpenVPN (tun0)", callback_data="switch_tun0", icon_custom_emoji_id=EMOJI_LOCK),
        ],
        [
            InlineKeyboardButton("🔄 Auto (Auto Select)", callback_data="switch_auto", icon_custom_emoji_id=EMOJI_REFRESH),
        ],
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)

    text = f"<b>Select VPN Backend:</b>\n\nActive: <code>{current}</code>\n\nChoose an option below to switch:"
    if update.message:
        await update.message.reply_text(text, reply_markup=reply_markup, parse_mode='HTML')


async def switch_vpn_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if query is None or query.data is None:
        return
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        try:
            await query.answer("Unauthorized", show_alert=True)
        except Exception:
            pass
        return

    target = query.data.replace("switch_", "")
    names = {
        "awg0": "AmneziaWG (awg0)",
        "tun0": "OpenVPN (tun0)",
        "auto": "Auto",
    }
    target_name = names.get(target, target)
    try:
        await query.answer(f"Switching to {target_name}...")
    except Exception:
        pass

    run_hotspot_command(["--switch-vpn", target])
    await asyncio.sleep(2)
    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)

    try:
        await query.edit_message_text(
            text=f"<b>Switched to {target_name}!</b>\n\n{status_text}",
            reply_markup=reply_markup,
            parse_mode='HTML'
        )
    except Exception as e:
        if "not modified" not in str(e).lower():
            logger.warning(f"Could not edit message after switch: {e}")


async def switch_vpn_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return

    target = context.args[0].lower() if context.args else "auto"
    if target not in ["awg0", "tun0", "auto", "wg0"]:
        if update.message:
            await update.message.reply_text("Usage: <code>/switch_vpn &lt;awg0|tun0|auto&gt;</code>", parse_mode='HTML')
        return

    if update.message:
        await update.message.reply_text(f"Switching VPN backend to <b>{target}</b>...", parse_mode='HTML')

    run_hotspot_command(["--switch-vpn", target])
    status_text = await get_status_text()
    reply_markup = make_status_keyboard(status_text)

    if update.message:
        await update.message.reply_text(text=status_text, reply_markup=reply_markup, parse_mode='HTML')


async def restart_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Restarting Hotspot...", reply_markup=MAIN_KEYBOARD)
    stdout, stderr, _ = run_hotspot_command(["--restart"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Restart Result:\n{response}")


async def restart_vpn_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Restarting VPN connection...", reply_markup=MAIN_KEYBOARD)
    stdout, stderr, _ = run_hotspot_command(["--restart-vpn"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Restart VPN Result:\n{response}")


async def fix_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    msg = await update.message.reply_text("Running auto-fix for hotspot and VPN...", reply_markup=MAIN_KEYBOARD)
    stdout, stderr, _ = run_hotspot_command(["--fix"])
    response = stdout if stdout else stderr
    await msg.edit_text(f"Fix Result:\n{response}")


async def clients_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    if update.message is None:
        return
    stdout, stderr, _ = run_hotspot_command(["--clients"])
    response = stdout if stdout else stderr
    await update.message.reply_text(response, reply_markup=MAIN_KEYBOARD)


async def handle_text_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle commands without slash (e.g., 'status' instead of '/status')"""
    if update.effective_user is None or not check_authorization(update.effective_user.id):
        return
    if update.message is None or update.message.text is None:
        return

    raw_text = update.message.text.strip().lower()
    text = re.sub(r'^[^\w/]+', '', raw_text).strip()
    normalized = text.replace(" ", "_")

    if text in ["status", "stat"] or normalized == "status":
        await status_command(update, context)
    elif text in ["switch vpn", "switch_vpn", "switch"] or normalized in ["switch_vpn", "switch"]:
        await switch_menu_command(update, context)
    elif text in ["ipv6", "ipv6 mode", "ipv6_mode", "/ipv6"] or normalized in ["ipv6", "ipv6_mode"]:
        await ipv6_menu_command(update, context)
    elif text.startswith("ipv6") or text.startswith("/ipv6"):
        parts = text.split()
        if len(parts) > 1 and parts[1] in ["drop", "reject", "off"]:
            context.args = [parts[1]]
            await ipv6_command(update, context)
        else:
            await ipv6_menu_command(update, context)
    elif text in ["restart"] or normalized == "restart":
        await restart_command(update, context)
    elif text in ["restart vpn", "restart_vpn", "vpn restart"] or normalized == "restart_vpn":
        await restart_vpn_command(update, context)
    elif text in ["fix", "auto fix", "autofix"] or normalized == "fix":
        await fix_command(update, context)
    elif text in ["clients", "client"] or normalized == "clients":
        await clients_command(update, context)
    elif text in ["help"] or normalized == "help":
        await help_command(update, context)
    elif text.startswith("switch_vpn") or text.startswith("switch ") or text in ["switch", "switch_awg", "switch_tun"]:
        parts = text.split()
        if len(parts) > 1:
            context.args = [parts[1]]
        elif text == "switch_awg":
            context.args = ["awg0"]
        elif text == "switch_tun":
            context.args = ["tun0"]
        else:
            context.args = ["auto"]
        await switch_vpn_command(update, context)


def main():
    if not BOT_TOKEN:
        logger.error("TELEGRAM_BOT_TOKEN not found in environment variables!")
        sys.exit(1)

    health_server = start_bot_health_server()
    try:
        app = Application.builder().token(BOT_TOKEN).build()

        app.add_handler(CommandHandler("start", start))
        app.add_handler(CommandHandler("status", status_command))
        app.add_handler(CommandHandler("restart", restart_command))
        app.add_handler(CommandHandler("restart_vpn", restart_vpn_command))
        app.add_handler(CommandHandler("switch_vpn", switch_vpn_command))
        app.add_handler(CommandHandler("switch", switch_menu_command))
        app.add_handler(CommandHandler("fix", fix_command))
        app.add_handler(CommandHandler("clients", clients_command))
        app.add_handler(CommandHandler("help", help_command))
        app.add_handler(CommandHandler("ipv6", ipv6_command))

        app.add_handler(CallbackQueryHandler(switch_vpn_callback, pattern="^switch_(awg0|tun0|auto)$"))
        app.add_handler(CallbackQueryHandler(ipv6_callback, pattern="^(ipv6_|menu_ipv6)"))
        app.add_handler(CallbackQueryHandler(refresh_callback, pattern="^refresh_status$"))

        app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text_message))

        logger.info("Starting bot polling...")
        _bot_ready.set()
        app.run_polling(drop_pending_updates=True)
    finally:
        _bot_ready.clear()
        health_server.shutdown()
        health_server.server_close()


if __name__ == "__main__":
    main()
