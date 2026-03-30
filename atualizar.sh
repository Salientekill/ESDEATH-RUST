#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.bot.pid"
BIN="$SCRIPT_DIR/esdeath/esdeath-bot"

echo "=== ESDEATH BOT — Atualizador ==="

CURRENT=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "nenhuma")
echo "Versão atual: $CURRENT"

# 1. Para o bot se estiver rodando
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Parando bot (PID $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 3
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

# 2. Backup do binário atual
if [ -f "$BIN" ]; then
    mkdir -p "$SCRIPT_DIR/.backups"
    cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}"
    # Manter apenas últimos 3 backups
    ls -t "$SCRIPT_DIR/.backups"/esdeath-bot.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi

# 3. Atualizar tudo (binário + scripts) via git pull
echo "Baixando atualizacao..."
git -C "$SCRIPT_DIR" pull --ff-only origin main

NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
echo ""
echo "Atualizado para $NEW!"
echo "Execute: bash start.sh"
