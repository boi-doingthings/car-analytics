#!/bin/zsh
# Rebuild web/*.json from the iCloud i20_book folder (read-only). Logs to data/collect.log.
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
BOOK="${I20_BOOK:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/i20_book}"
# Node: I20_NODE, else PATH, else the newest nvm install (same lookup as serve.py).
NODE="${I20_NODE:-$(command -v node)}"
[[ -z "$NODE" ]] && NODE=(~/.nvm/versions/node/*/bin/node(N.non[-1]))
[[ -z "$NODE" ]] && { echo "Node.js not found — install it or set I20_NODE." | tee -a data/collect.log >&2; exit 127; }
"$NODE" analytics/cli.mjs --book "$BOOK" --out web >> data/collect.log 2>&1
