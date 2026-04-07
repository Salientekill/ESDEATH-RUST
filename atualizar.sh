#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.bot.pid"
BIN="$SCRIPT_DIR/esdeath/esdeath-bot"
PUBLIC_REPO="https://github.com/Salientekill/ESDEATH-RUST.git"
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

    BACKUP_DIR="$SCRIPT_DIR/.backups"
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo "Nenhum backup encontrado."
        exit 1
    fi

    echo "Backups disponíveis:"
    ls -t "$BACKUP_DIR"/esdeath-bot.* 2>/dev/null | while read -r f; do
        echo "  - $(basename "$f" | sed 's/esdeath-bot\.//')"
    done
    echo ""

    read -p "Qual versão restaurar? (ex: v1.25): " TARGET
    if [ -z "$TARGET" ]; then
        echo "Cancelado."
        exit 0
    fi

    BACKUP="$BACKUP_DIR/esdeath-bot.${TARGET}"
    if [ ! -f "$BACKUP" ]; then
        echo "Backup '$TARGET' não encontrado."
        exit 1
    fi

    echo ""
    read -p "Confirma rollback de $CURRENT → $TARGET? [s/N]: " CONFIRM
    if [ "${CONFIRM,,}" != "s" ]; then
        echo "Cancelado."
        exit 0
    fi

    stop_bot

    cp "$BACKUP" "$BIN"
    chmod +x "$BIN"
    echo "$TARGET" > "$SCRIPT_DIR/.version"

    echo ""
    echo "Rollback para $TARGET concluído!"
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

# Baixa versão mais recente do repo público
echo "Baixando atualizacao..."
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet

# Copia binário
cp "$TMPDIR/pub/esdeath/esdeath-bot" "$BIN"
chmod +x "$BIN"

# Copia scripts atualizados
cp "$TMPDIR/pub/start.sh" "$SCRIPT_DIR/start.sh"
chmod +x "$SCRIPT_DIR/start.sh"
cp "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh"
chmod +x "$SCRIPT_DIR/atualizar.sh"
cp "$TMPDIR/pub/setup.sh" "$SCRIPT_DIR/setup.sh"
chmod +x "$SCRIPT_DIR/setup.sh"

# Copia template (não sobrescreve config do usuário)
cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template"

# Atualiza versão
cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"

NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
echo ""
echo "Atualizado para $NEW!"
echo "Execute: bash start.sh"
echo ""
echo "Para rollback: bash atualizar.sh rollback"
