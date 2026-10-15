#!/bin/sh
# vpnpool: emit a JSON status snapshot for the LuCI dashboard / rpcd / the Telegram bot.
# The work is done by status.uc in ONE ucode process (uci read once, files read directly,
# parser results cached by mtime) — see ROADMAP 3.7. `exec` keeps it a single process.
exec ucode /usr/libexec/vpnpool/status.uc "$@"
