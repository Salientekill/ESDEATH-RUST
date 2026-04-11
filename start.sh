#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSL_TARGET="x86_64-unknown-linux-musl"
PID_FILE="$SCRIPT_DIR/.bot.pid"
DB="${BOT_DB_PATH:-"$SCRIPT_DIR/dados/DB/ESDEATH_AUTH.db"}"

# ── Detecta binário: compilado (dev) ou pré-built (cliente) ────────────────
DEV_BIN="$SCRIPT_DIR/target/$MUSL_TARGET/release/esdeath-bot"
PUB_BIN="$SCRIPT_DIR/esdeath/esdeath-bot"

if [ -f "$DEV_BIN" ]; then
    BOT_BIN="$DEV_BIN"
elif [ -f "$PUB_BIN" ]; then
    BOT_BIN="$PUB_BIN"
else
    BOT_BIN=""
fi

case "${1:-}" in
    comp)
        cargo build --release --target "$MUSL_TARGET" --manifest-path "$SCRIPT_DIR/Cargo.toml"
        exit 0
        ;;
    recomp)
        cargo clean --manifest-path "$SCRIPT_DIR/Cargo.toml"
        cargo build --release --target "$MUSL_TARGET" --manifest-path "$SCRIPT_DIR/Cargo.toml"
        exit 0
        ;;
    update|atualizar)
        if [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
            echo "Atualizando whatsapp-rust..."
            git -C "$SCRIPT_DIR/whatsapp-rust" stash -q 2>/dev/null || true
            git -C "$SCRIPT_DIR/whatsapp-rust" pull origin main
            git -C "$SCRIPT_DIR/whatsapp-rust" stash pop -q 2>/dev/null || true
            cargo build --release --target "$MUSL_TARGET" --manifest-path "$SCRIPT_DIR/Cargo.toml"
        elif [ -f "$SCRIPT_DIR/atualizar.sh" ]; then
            exec bash "$SCRIPT_DIR/atualizar.sh"
        else
            echo "Nenhum metodo de atualizacao disponivel."
            exit 1
        fi
        exit 0
        ;;
    rollback)
        BACKUP_DIR="$SCRIPT_DIR/.backups"
        BACKUP=$(ls -t "$BACKUP_DIR"/esdeath-bot.* 2>/dev/null | head -1)
        if [ -z "$BACKUP" ]; then
            echo "Nenhum backup encontrado."
            exit 1
        fi
        cp "$BACKUP" "$PUB_BIN"
        chmod +x "$PUB_BIN"
        VERSION=$(basename "$BACKUP" | sed 's/esdeath-bot\.//')
        echo "$VERSION" > "$SCRIPT_DIR/.version"
        echo "Revertido para $VERSION"
        exit 0
        ;;
    debug)
        export WBOT_DEBUG=1
        export RUST_LOG=debug,whatsapp_rust_tokio_transport=trace
        ;;
    debug2)
        export WBOT_DEBUG=2
        export RUST_LOG=whatsapp_rust_tokio_transport=trace
        ;;
    reset)
        rm -f "$DB" "$DB-shm" "$DB-wal"
        echo "Sessao removida. Reconectando..."
        ;;
    "")
        ;;
    *)
        echo "Comando desconhecido: $1"
        echo "Uso: bash start.sh [comp|recomp|update|rollback|debug|debug2|reset]"
        exit 1
        ;;
esac

# Verifica se o binário existe
if [ -z "$BOT_BIN" ]; then
    if [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
        echo "Binario nao encontrado. Compile com: bash start.sh comp"
    else
        echo "Binario nao encontrado. Execute: bash setup.sh"
    fi
    exit 1
fi

# Mata TODAS as instancias anteriores deste bot
# 1) Via PID file — valida que é realmente um processo do bot antes de matar.
#    Em containers (Pterodactyl) PIDs resetam e podem colidir com o proprio
#    supervisor/bash pai, causando suicidio do start.sh.
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && [ "$OLD_PID" != "$PPID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        OLD_CMD=$(cat "/proc/$OLD_PID/cmdline" 2>/dev/null | tr '\0' ' ')
        if echo "$OLD_CMD" | grep -qE "esdeath-bot|start\.sh"; then
            echo "Fechando instancia anterior (PID $OLD_PID)..."
            kill "$OLD_PID" 2>/dev/null || true
            for i in $(seq 1 10); do
                kill -0 "$OLD_PID" 2>/dev/null || break
                sleep 0.5
            done
            kill -9 "$OLD_PID" 2>/dev/null || true
        else
            echo "PID file stale (PID $OLD_PID nao e do bot, ignorando)."
        fi
    fi
    rm -f "$PID_FILE"
fi

# 2) Fallback: mata qualquer processo com este binario
for BIN_PATTERN in "$DEV_BIN" "$PUB_BIN"; do
    if pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
        echo "Fechando instancias orfas ($BIN_PATTERN)..."
        pkill -f "$BIN_PATTERN" 2>/dev/null || true
        sleep 2
        pkill -9 -f "$BIN_PATTERN" 2>/dev/null || true
    fi
done

# Supervisor: reinicia em Ctrl+C, encerra em 2x Ctrl+C (<2s) ou Ctrl+Z
BOT_PID=""
LAST_INT=0
SHOULD_EXIT=0
TRAP_RESTART=0

stop_bot() {
    if [ -n "$BOT_PID" ] && kill -0 "$BOT_PID" 2>/dev/null; then
        kill -TERM "$BOT_PID" 2>/dev/null || true
        for _ in $(seq 1 4); do
            kill -0 "$BOT_PID" 2>/dev/null || { wait "$BOT_PID" 2>/dev/null || true; return 0; }
            sleep 0.25
        done
        kill -KILL "$BOT_PID" 2>/dev/null || true
        wait "$BOT_PID" 2>/dev/null || true
    fi
}

on_sigint() {
    local now
    now=$(date +%s)
    if [ "$LAST_INT" -gt 0 ] && [ $((now - LAST_INT)) -le 2 ]; then
        echo ""
        echo -e "\e[92m✅ Encerramento completo (Ctrl+C duplo). Parando o script.\e[0m"
        SHOULD_EXIT=1
        stop_bot
        return
    fi
    LAST_INT=$now
    TRAP_RESTART=1
    echo ""
    echo -e "\e[93m♻️  Reiniciando bot... (Ctrl+C de novo em <=2s para encerrar)\e[0m"
    stop_bot
}

on_sigtstp() {
    echo ""
    echo -e "\e[92m✅ Ctrl+Z recebido. Encerrando.\e[0m"
    SHOULD_EXIT=1
    stop_bot
}

on_sigterm() {
    SHOULD_EXIT=1
    stop_bot
}

trap on_sigint  INT
trap on_sigtstp TSTP
trap on_sigterm TERM

# PID do supervisor (quem mata este PID encerra tudo via trap TERM)
echo "$$" > "$PID_FILE"

echo -e "\e[95m════════════════════════════════════════════════════════════════════════════════\e[0m"
echo -e "\e[96m                       🤖 ESDEATH BOT - INICIALIZAÇÃO                          \e[0m"
echo -e "\e[95m════════════════════════════════════════════════════════════════════════════════\e[0m"
echo -e "\e[93m🔧 SUPERVISOR DE PROCESSOS ATIVADO\e[0m"
echo -e "\e[94m⌨️   Ctrl+C        → reinicia o bot\e[0m"
echo -e "\e[94m⌨️   Ctrl+C 2x     → encerra tudo (dentro de 2s)\e[0m"
echo -e "\e[94m⌨️   Ctrl+Z        → encerra tudo\e[0m"
echo -e "\e[95m════════════════════════════════════════════════════════════════════════════════\e[0m"

while [ "$SHOULD_EXIT" = "0" ]; do
    echo -e "\e[32m🚀 ESDEATH BOT ESTÁ INICIANDO AGUARDE...\e[0m"
    "$BOT_BIN" </dev/tty &
    BOT_PID=$!
    EXIT_CODE=0
    wait "$BOT_PID" 2>/dev/null || EXIT_CODE=$?

    if [ "$SHOULD_EXIT" = "1" ]; then
        break
    fi

    if [ "$TRAP_RESTART" = "1" ]; then
        TRAP_RESTART=0
    else
        echo -e "\e[91m⚠️  Bot saiu (code=$EXIT_CODE). Reiniciando em 1s...\e[0m"
        sleep 1
    fi
done

rm -f "$PID_FILE"
echo -e "\e[92m✅ Bot encerrado.\e[0m"
