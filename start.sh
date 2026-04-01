#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_BIN="$SCRIPT_DIR/esdeath/esdeath-bot"
PID_FILE="$SCRIPT_DIR/.bot.pid"
DB="$SCRIPT_DIR/dados/DB/ESDEATH_AUTH.db"

case "${1:-}" in
    update|atualizar)
        exec bash "$SCRIPT_DIR/atualizar.sh"
        ;;
    debug)
        export WBOT_DEBUG=1
        export RUST_LOG=debug
        ;;
    reset)
        rm -f "$DB" "$DB-shm" "$DB-wal"
        echo "Sessao removida. Reconectando..."
        ;;
    rollback)
        BACKUP_DIR="$SCRIPT_DIR/.backups"
        BACKUP=$(ls -t "$BACKUP_DIR"/esdeath-bot.* 2>/dev/null | head -1)
        if [ -z "$BACKUP" ]; then
            echo "Nenhum backup encontrado."
            exit 1
        fi
        cp "$BACKUP" "$BOT_BIN"
        chmod +x "$BOT_BIN"
        VERSION=$(basename "$BACKUP" | sed 's/esdeath-bot\.//')
        echo "$VERSION" > "$SCRIPT_DIR/.version"
        echo "Revertido para $VERSION"
        exit 0
        ;;
    *)
        if [ -n "${1:-}" ]; then
            echo "Comando desconhecido: $1"
            echo "Uso: bash start.sh [update|debug|reset|rollback]"
            exit 1
        fi
        ;;
esac

if [ ! -f "$BOT_BIN" ]; then
    echo "Binario nao encontrado. Execute: bash setup.sh"
    exit 1
fi

# Mata instancias anteriores
# 1) Via PID file
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Fechando instancia anterior (PID $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        for i in $(seq 1 10); do
            kill -0 "$OLD_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

# 2) Fallback: mata qualquer processo com este binario
if pgrep -f "$BOT_BIN" >/dev/null 2>&1; then
    echo "Fechando instancias orfas..."
    pkill -f "$BOT_BIN" 2>/dev/null || true
    sleep 2
    pkill -9 -f "$BOT_BIN" 2>/dev/null || true
fi

# Inicia em foreground
echo "Iniciando bot..."
echo "$$" > "$PID_FILE"
exec "$BOT_BIN"
