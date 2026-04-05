#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.bot.pid"
BIN="$SCRIPT_DIR/esdeath/esdeath-bot"
MODE="${1:-update}"

CURRENT=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "nenhuma")

# Função: para o bot se estiver rodando
stop_bot() {
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
}

# ═══════════════════════════════════════════════════════════
# Modo ROLLBACK
# ═══════════════════════════════════════════════════════════
if [ "$MODE" = "rollback" ]; then
    echo "=== ESDEATH BOT — Rollback ==="
    echo "Versão atual: $CURRENT"
    echo ""

    # Busca tags remotas para garantir lista atualizada
    git -C "$SCRIPT_DIR" fetch --tags --quiet 2>/dev/null || true

    # Lista versões disponíveis (tags)
    echo "Versões disponíveis:"
    TAGS=$(git -C "$SCRIPT_DIR" tag -l 'v*' | sort -V -r)
    if [ -z "$TAGS" ]; then
        echo "  Nenhuma versão disponível para rollback."
        exit 1
    fi
    echo "$TAGS" | head -10 | sed 's/^/  - /'
    echo ""

    read -p "Qual versão restaurar? (ex: v1.17): " TARGET
    if [ -z "$TARGET" ]; then
        echo "Cancelado."
        exit 0
    fi

    # Valida se a tag existe
    if ! git -C "$SCRIPT_DIR" rev-parse "$TARGET" >/dev/null 2>&1; then
        echo "Versão '$TARGET' não encontrada."
        exit 1
    fi

    echo ""
    read -p "Confirma rollback de $CURRENT → $TARGET? [s/N]: " CONFIRM
    if [ "${CONFIRM,,}" != "s" ]; then
        echo "Cancelado."
        exit 0
    fi

    stop_bot

    # Backup do binário atual antes de sobrescrever
    if [ -f "$BIN" ]; then
        mkdir -p "$SCRIPT_DIR/.backups"
        cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}"
    fi

    echo "Restaurando $TARGET..."
    git -C "$SCRIPT_DIR" checkout "$TARGET" -- . 2>&1 | grep -v "^$" || true

    NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "$TARGET")
    echo ""
    echo "Rollback para $NEW concluído!"
    echo "Execute: bash start.sh"
    exit 0
fi

# ═══════════════════════════════════════════════════════════
# Modo UPDATE (padrão)
# ═══════════════════════════════════════════════════════════
echo "=== ESDEATH BOT — Atualizador ==="
echo "Versão atual: $CURRENT"

stop_bot

# Backup do binário atual
if [ -f "$BIN" ]; then
    mkdir -p "$SCRIPT_DIR/.backups"
    cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}"
    # Manter apenas últimos 3 backups
    ls -t "$SCRIPT_DIR/.backups"/esdeath-bot.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi

# Garante que estamos em main (pode ter vindo de um rollback)
git -C "$SCRIPT_DIR" checkout main --quiet 2>/dev/null || true

# Atualizar tudo (binário + scripts) via git pull
echo "Baixando atualizacao..."
git -C "$SCRIPT_DIR" pull --ff-only origin main

NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
echo ""
echo "Atualizado para $NEW!"
echo "Execute: bash start.sh"
echo ""
echo "Para rollback: bash atualizar.sh rollback"
