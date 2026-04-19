#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.bot.pid"
BIN="$SCRIPT_DIR/esdeath/esdeath-bot"
PUBLIC_REPO="https://github.com/Salientekill/ESDEATH-RUST.git"
MODE="${1:-update}"

CURRENT=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "nenhuma")

# Função: para o bot se estiver rodando (mata supervisor start.sh também)
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

# Função: mata só os processos do binário do bot, preservando o supervisor.
# Usado no modo 'auto' (chamado de dentro do próprio bot) para que o
# start.sh detecte a saída e relance automaticamente com a nova versão.
stop_bot_bin_only() {
    for BIN_PATTERN in "$BIN" "$SCRIPT_DIR/target/x86_64-unknown-linux-musl/release/esdeath-bot"; do
        if pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
            echo "Matando binário do bot ($BIN_PATTERN)..."
            pkill -TERM -f "$BIN_PATTERN" 2>/dev/null || true
        fi
    done
}

# ═══════════════════════════════════════════════════════════
# Modo AUTO — invocado pelo próprio bot (comando !atualizarbot).
# Não toca no PID do supervisor: baixa nova versão, troca o
# binário, mata só o processo atual do bot. O start.sh detecta
# o exit e relança automaticamente com a nova versão.
# ═══════════════════════════════════════════════════════════
if [ "$MODE" = "auto" ]; then
    echo "=== ESDEATH BOT — Atualizacao automatica ==="
    echo "Versao atual: $CURRENT"

    # Remove .bot.pid stale (mesma motivacao do modo update — ver abaixo).
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -z "$OLD_PID" ] || ! kill -0 "$OLD_PID" 2>/dev/null; then
            rm -f "$PID_FILE"
        else
            OLD_CMD=$(cat "/proc/$OLD_PID/cmdline" 2>/dev/null | tr '\0' ' ')
            if ! echo "$OLD_CMD" | grep -qE "esdeath-bot|start\.sh"; then
                rm -f "$PID_FILE"
            fi
        fi
    fi

    # Backup do binário atual
    if [ -f "$BIN" ]; then
        mkdir -p "$SCRIPT_DIR/.backups"
        cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}"
        ls -t "$SCRIPT_DIR/.backups"/esdeath-bot.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi

    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    echo "Baixando atualizacao..."
    if ! git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet; then
        echo "ERRO: falha ao clonar repositorio."
        exit 1
    fi

    if [ ! -f "$TMPDIR/pub/esdeath/esdeath-bot" ]; then
        echo "ERRO: binario nao encontrado no repositorio."
        exit 1
    fi

    # Copia via rename atômico para evitar ETXTBSY em containers
    # (cp direto sobre binário em execução falha em alguns ambientes)
    TMP_BIN="${BIN}.new.$$"
    cp "$TMPDIR/pub/esdeath/esdeath-bot" "$TMP_BIN"
    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$BIN"

    # Copia scripts atualizados
    [ -f "$TMPDIR/pub/start.sh" ]     && cp "$TMPDIR/pub/start.sh"     "$SCRIPT_DIR/start.sh"     && chmod +x "$SCRIPT_DIR/start.sh"
    [ -f "$TMPDIR/pub/atualizar.sh" ] && cp "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh" && chmod +x "$SCRIPT_DIR/atualizar.sh"
    [ -f "$TMPDIR/pub/setup.sh" ]     && cp "$TMPDIR/pub/setup.sh"     "$SCRIPT_DIR/setup.sh"     && chmod +x "$SCRIPT_DIR/setup.sh"

    [ -f "$TMPDIR/pub/esdeath/bot_config.json.template" ] && \
        cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template" 2>/dev/null || true

    # Dados JSON: adiciona os que faltam, preserva os existentes (edições do cliente)
    if [ -d "$TMPDIR/pub/dados/org/json" ]; then
        mkdir -p "$SCRIPT_DIR/dados/org/json"
        for f in "$TMPDIR/pub/dados/org/json/"*.json; do
            [ -e "$f" ] || continue
            dest="$SCRIPT_DIR/dados/org/json/$(basename "$f")"
            [ -f "$dest" ] || cp "$f" "$dest"
        done
    fi

    [ -f "$TMPDIR/pub/.version" ] && cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"

    NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
    echo "Atualizado: $CURRENT -> $NEW"

    # Mata só o binário do bot (supervisor continua vivo e relança).
    # Delay pra dar tempo da mensagem ser enviada antes do kill.
    (sleep 2 && stop_bot_bin_only) &
    exit 0
fi

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
#
# NÃO mata o supervisor (start.sh) — em containers (Pterodactyl)
# o PID_FILE contém o PID do start.sh, e matá-lo derruba o
# servidor inteiro antes do download terminar. Estratégia:
# 1) baixa tudo no tmp; 2) só então troca binário e mata o
# binário em execução; 3) supervisor (se houver) relança
# automaticamente com a versão nova.
# ═══════════════════════════════════════════════════════════
echo "=== ESDEATH BOT — Atualizador ==="
echo "Versão atual: $CURRENT"

# Remove .bot.pid stale: em panéis tipo Bronxys, ao reiniciar o container o
# arquivo persiste com PID inválido (processo antigo já morreu). Sem essa
# limpeza, o próximo `start.sh` pode tentar matar um PID reciclado por outro
# processo (ex: o próprio supervisor do panel) e o bot não sobe.
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -z "$OLD_PID" ] || ! kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Limpando .bot.pid stale (PID $OLD_PID nao existe)."
        rm -f "$PID_FILE"
    else
        OLD_CMD=$(cat "/proc/$OLD_PID/cmdline" 2>/dev/null | tr '\0' ' ')
        if ! echo "$OLD_CMD" | grep -qE "esdeath-bot|start\.sh"; then
            echo "Limpando .bot.pid stale (PID $OLD_PID nao e do bot: $OLD_CMD)."
            rm -f "$PID_FILE"
        fi
    fi
fi

# Backup do binário atual
if [ -f "$BIN" ]; then
    mkdir -p "$SCRIPT_DIR/.backups"
    cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}"
    ls -t "$SCRIPT_DIR/.backups"/esdeath-bot.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi

echo "Baixando atualizacao..."
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if ! git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet; then
    echo "ERRO: falha ao clonar repositorio (git instalado e rede ok?)."
    exit 1
fi

if [ ! -f "$TMPDIR/pub/esdeath/esdeath-bot" ]; then
    echo "ERRO: binario nao encontrado no repositorio."
    exit 1
fi

# Rename atômico: evita ETXTBSY com binário em uso
TMP_BIN="${BIN}.new.$$"
cp "$TMPDIR/pub/esdeath/esdeath-bot" "$TMP_BIN"
chmod +x "$TMP_BIN"
mv "$TMP_BIN" "$BIN"

# Scripts e template (best-effort)
[ -f "$TMPDIR/pub/start.sh" ]     && cp "$TMPDIR/pub/start.sh"     "$SCRIPT_DIR/start.sh"     && chmod +x "$SCRIPT_DIR/start.sh"
[ -f "$TMPDIR/pub/atualizar.sh" ] && cp "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh" && chmod +x "$SCRIPT_DIR/atualizar.sh"
[ -f "$TMPDIR/pub/setup.sh" ]     && cp "$TMPDIR/pub/setup.sh"     "$SCRIPT_DIR/setup.sh"     && chmod +x "$SCRIPT_DIR/setup.sh"
[ -f "$TMPDIR/pub/esdeath/bot_config.json.template" ] && \
    cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template" 2>/dev/null || true

# Dados JSON: adiciona os que faltam, preserva os existentes (edições do cliente)
if [ -d "$TMPDIR/pub/dados/org/json" ]; then
    mkdir -p "$SCRIPT_DIR/dados/org/json"
    for f in "$TMPDIR/pub/dados/org/json/"*.json; do
        [ -e "$f" ] || continue
        dest="$SCRIPT_DIR/dados/org/json/$(basename "$f")"
        [ -f "$dest" ] || cp "$f" "$dest"
    done
fi

[ -f "$TMPDIR/pub/.version" ] && cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"

NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
echo ""
echo "Atualizado: $CURRENT -> $NEW"

# Reinicia: mata só o binário (preserva start.sh para relançar).
if pgrep -f "$BIN" >/dev/null 2>&1 \
   || pgrep -f "$SCRIPT_DIR/target/x86_64-unknown-linux-musl/release/esdeath-bot" >/dev/null 2>&1; then
    echo "Reiniciando bot (supervisor relança)..."
    stop_bot_bin_only
else
    echo "Bot nao estava rodando. Execute: bash start.sh"
fi

echo ""
echo "Para rollback: bash atualizar.sh rollback"
