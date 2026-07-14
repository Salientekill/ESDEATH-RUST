#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSL_TARGET="x86_64-unknown-linux-musl"
PID_FILE="$SCRIPT_DIR/.bot.pid"
DB="${BOT_DB_PATH:-"$SCRIPT_DIR/dados/DB/ESDEATH_AUTH.db"}"

# ── Detecta binário: comp2 (debug nativo) > comp (musl release) > pub ──────
DEV_BIN="$SCRIPT_DIR/target/$MUSL_TARGET/release/esdeath-bot"
DBG_BIN="$SCRIPT_DIR/target/debug/esdeath-bot"
PUB_BIN="$SCRIPT_DIR/esdeath/esdeath-bot"
# Binario de profiling do dhat (build via `bash start.sh dhat`) — rodado por
# `./start.sh ram`. Nunca entra na deteccao automatica de BOT_BIN acima.
PROF_BIN="$SCRIPT_DIR/target/$MUSL_TARGET/profiling/esdeath-bot"

if [ -f "$DBG_BIN" ] && [ "$DBG_BIN" -nt "$DEV_BIN" ] 2>/dev/null; then
    BOT_BIN="$DBG_BIN"
elif [ -f "$DEV_BIN" ]; then
    BOT_BIN="$DEV_BIN"
elif [ -f "$DBG_BIN" ]; then
    BOT_BIN="$DBG_BIN"
elif [ -f "$PUB_BIN" ]; then
    BOT_BIN="$PUB_BIN"
else
    BOT_BIN=""
fi

# ── Build MUSL via cargo-zigbuild ──────────────────────────────────────────
# O comando !akinator usa o crate `wreq` (BoringSSL) para passar o fingerprint
# TLS do Cloudflare do Akinator. BoringSSL é C++ e não cross-compila pro target
# MUSL com o musl-gcc comum; usamos `cargo zigbuild` (o `zig cc` traz libc++ +
# musl). Pré-requisitos, instalados UMA vez no servidor de build:
#   uv tool install ziglang        # binário do zig (PyPI oficial)
#   cargo install cargo-zigbuild   # wrapper de cross-compile (crates.io)
ensure_zig() {
    if ! command -v zig >/dev/null 2>&1; then
        if command -v python-zig >/dev/null 2>&1; then
            printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v python-zig)" > "$HOME/.cargo/bin/zig"
            chmod +x "$HOME/.cargo/bin/zig"
        else
            echo "ERRO: zig não encontrado. Instale com: uv tool install ziglang" >&2
            return 1
        fi
    fi
    if ! cargo zigbuild --help >/dev/null 2>&1; then
        echo "ERRO: cargo-zigbuild ausente. Instale com: cargo install cargo-zigbuild" >&2
        return 1
    fi
}
musl_build() {
    ensure_zig || return 1
    # Protege os bots em produção (mesmo servidor, 4 cores): `nice -n 19` cede CPU
    # pros bots; `-j 2` + CMAKE limitado usam no máx ~2 cores, deixando 2 livres —
    # evita saturar a CPU e causar latência/desconexão dos bots durante o build.
    local feats=""
    [ "${1:-}" = "jemalloc" ] && feats="--features jemalloc"
    CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" nice -n 19 \
        cargo zigbuild --release --target "$MUSL_TARGET" -j "${BUILD_JOBS:-2}" \
        $feats --manifest-path "$SCRIPT_DIR/Cargo.toml"
}

case "${1:-}" in
    comp)
        # comp [jemalloc] -> alocador de producao jemalloc (RSS desce via decay).
        # Sem arg = CountingAlloc (memmon com heap-vivo real).
        musl_build "${2:-}"
        BUILD_STATUS=$?
        # Não remove target/release ou target/debug — esses são caches de
        # `cargo check` e `comp2`, úteis pra dev rápido. Para limpar mesmo,
        # use `bash start.sh clean`. Mantém só o sweep incremental.
        if [ $BUILD_STATUS -eq 0 ] && command -v cargo-sweep >/dev/null 2>&1; then
            cargo sweep --time 3 "$SCRIPT_DIR" >/dev/null 2>&1 || true
        fi
        exit $BUILD_STATUS
        ;;
    comp2)
        # Build nativo debug — muito mais rápido para testar alterações
        cargo build --manifest-path "$SCRIPT_DIR/Cargo.toml"
        exit 0
        ;;
    recomp)
        cargo clean --manifest-path "$SCRIPT_DIR/Cargo.toml"
        musl_build
        BUILD_STATUS=$?
        if [ $BUILD_STATUS -eq 0 ] && command -v cargo-sweep >/dev/null 2>&1; then
            cargo sweep --time 3 "$SCRIPT_DIR" >/dev/null 2>&1 || true
        fi
        exit $BUILD_STATUS
        ;;
    dhat)
        # Build de PROFILING do dhat (Camada 3 do memmon): feature `dhat-heap`
        # troca o alocador pelo profiler; perfil `profiling` mantem debug info e
        # nao faz strip; RUSTFLAGS forca frame-pointers + unwind-tables pra o
        # backtrace crate CAMINHAR a pilha e simbolizar os callsites que alocam.
        # Sem isso o dhat-heap.json sai com ftbl=['[root]'] / fs=[] (so bytes,
        # sem nomes). Build-only (como `comp`): rode o binario, gere carga, use
        # !dhatdump (ou SIGUSR1) e analise:
        #   cargo run --bin dhat_report -- logs/dhat-heap.json
        ensure_zig || exit 1
        RUSTFLAGS="${RUSTFLAGS:-} -Cforce-frame-pointers=yes -Cforce-unwind-tables=yes" \
        CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" nice -n 19 \
            cargo zigbuild --profile profiling --features dhat-heap \
            --target "$MUSL_TARGET" -j "${BUILD_JOBS:-2}" \
            --manifest-path "$SCRIPT_DIR/Cargo.toml"
        BUILD_STATUS=$?
        if [ $BUILD_STATUS -eq 0 ]; then
            echo "Binario de profiling: target/$MUSL_TARGET/profiling/esdeath-bot"
            echo "Rode com: ./start.sh ram   (gerenciado: PID/stop/supervisor)"
            echo "Gere carga, dispare !dhatdump; depois analise com:"
            echo "  cargo run --bin dhat_report -- logs/dhat-heap.json"
        fi
        exit $BUILD_STATUS
        ;;
    clean)
        # Limpeza explícita de artefatos não-musl — equivalente ao antigo
        # comportamento do `comp`, mas só roda quando você pede.
        rm -rf "$SCRIPT_DIR/target/release" "$SCRIPT_DIR/target/debug" 2>/dev/null || true
        if command -v cargo-sweep >/dev/null 2>&1; then
            cargo sweep --time 3 "$SCRIPT_DIR" >/dev/null 2>&1 || true
        fi
        echo "Artefatos não-musl removidos. Cache musl mantido."
        exit 0
        ;;
    update|atualizar)
        if [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
            echo "Atualizando whatsapp-rust..."
            git -C "$SCRIPT_DIR/whatsapp-rust" stash -q 2>/dev/null || true
            git -C "$SCRIPT_DIR/whatsapp-rust" pull origin main
            git -C "$SCRIPT_DIR/whatsapp-rust" stash pop -q 2>/dev/null || true
            musl_build
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
    ram)
        # ./start.sh ram [dhat|jemalloc]
        #   com arg -> builda o profiler escolhido (default jemalloc = Rust + libs C)
        #   sem arg -> roda o binario de profiling ja buildado
        # Roda pela MESMA logica de PID/stop/supervisor. NAO e producao (lento).
        # Ao SAIR (Ctrl+C 2x): dhat -> !dhatdump/logs/dhat-heap.json ; jemalloc ->
        # logs/jeprof.<pid>.*.heap. Depois volte ao normal com `./start.sh`.
        case "${2:-}" in
            "") ;;
            dhat | jemalloc)
                FEAT="jemalloc-prof"
                [ "$2" = "dhat" ] && FEAT="dhat-heap"
                ensure_zig || exit 1
                echo "Buildando profiling ($2, feature $FEAT)..."
                CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" nice -n 19 \
                    cargo zigbuild --profile profiling --features "$FEAT" \
                    --target "$MUSL_TARGET" -j "${BUILD_JOBS:-2}" \
                    --manifest-path "$SCRIPT_DIR/Cargo.toml" || exit 1
                ;;
            *)
                echo "Uso: ./start.sh ram [dhat|jemalloc]  (sem arg = roda o ja buildado)"
                exit 1
                ;;
        esac
        if [ ! -f "$PROF_BIN" ]; then
            echo "Binario de profiling nao encontrado. Rode: ./start.sh ram jemalloc  (ou dhat)"
            exit 1
        fi
        BOT_BIN="$PROF_BIN"
        # jemalloc: ativa prof + dump ao sair (logs/jeprof.<pid>.*.heap). Se for
        # build dhat, o MALLOC_CONF e ignorado (nao ha jemalloc pra ler).
        export MALLOC_CONF="prof:true,prof_active:true,prof_prefix:logs/jeprof,prof_final:true,lg_prof_sample:19"
        echo -e "\e[93m⚠️  PROFILING — NAO e producao. Depois volte com ./start.sh\e[0m"
        ;;
    "")
        ;;
    *)
        echo "Comando desconhecido: $1"
        echo "Uso: bash start.sh [comp|comp2|recomp|dhat|ram|clean|update|rollback|debug|debug2|reset]"
        echo "     ram [dhat|jemalloc] = builda o profiler e roda (default jemalloc)"
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
for BIN_PATTERN in "$DEV_BIN" "$PUB_BIN" "$PROF_BIN"; do
    if pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
        echo "Fechando instancias orfas ($BIN_PATTERN)..."
        pkill -f "$BIN_PATTERN" 2>/dev/null || true
        sleep 2
        pkill -9 -f "$BIN_PATTERN" 2>/dev/null || true
    fi
done

# Garante que ^C/^Z estão mapeados pros sinais corretos
# (alguns terminais/containers desbindam intr, deixando Ctrl+C sem efeito)
stty intr ^C susp ^Z 2>/dev/null || true

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
    _INT_NOW=$(date +%s)
    if [ "$LAST_INT" -gt 0 ] && [ $((_INT_NOW - LAST_INT)) -le 2 ]; then
        echo ""
        echo -e "\e[92m✅ Encerramento completo (Ctrl+C duplo). Parando o script.\e[0m"
        SHOULD_EXIT=1
        stop_bot
        return
    fi
    LAST_INT=$_INT_NOW
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

# jemalloc (build `comp jemalloc`): decay devolve memoria liberada pro SO -> a
# RSS desce apos picos de midia. Ignorado por build nao-jemalloc. `ram` ja setou
# o seu (prof), entao `:-` preserva.
export MALLOC_CONF="${MALLOC_CONF:-background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000}"

# PID do supervisor (quem mata este PID encerra tudo via trap TERM)
echo "$$" > "$PID_FILE"

echo -e "\e[95m══════════════════════════════════════════════════════════════════════════\e[0m"
echo -e "\e[96m                       🤖 ESDEATH BOT - INICIALIZAÇÃO                          \e[0m"
echo -e "\e[95m══════════════════════════════════════════════════════════════════════════\e[0m"
echo -e "\e[93m🔧 SUPERVISOR DE PROCESSOS ATIVADO\e[0m"
echo -e "\e[94m⌨️   Ctrl+C        → reinicia o bot\e[0m"
echo -e "\e[94m⌨️   Ctrl+C 2x     → encerra tudo (dentro de 2s)\e[0m"
echo -e "\e[94m⌨️   Ctrl+Z        → encerra tudo\e[0m"
echo -e "\e[95m══════════════════════════════════════════════════════════════════════════\e[0m"

while [ "$SHOULD_EXIT" = "0" ]; do
    echo -e "\e[32m🚀 ESDEATH BOT ESTÁ INICIANDO AGUARDE...\e[0m"
    # Stdin do bot: /dev/tty quando interativo (pair code), /dev/null em
    # ambientes sem tty (container, systemd). Sem o fallback, processos em
    # background que tentam ler de /dev/tty recebem SIGTTIN e ficam parados —
    # parece "travado" no restart após Ctrl+C porque o tty fica inconsistente.
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        "$BOT_BIN" </dev/tty &
    else
        "$BOT_BIN" </dev/null &
    fi
    BOT_PID=$!
    EXIT_CODE=0
    wait "$BOT_PID" 2>/dev/null || EXIT_CODE=$?

    if [ "$SHOULD_EXIT" = "1" ]; then
        break
    fi

    if [ "$TRAP_RESTART" = "1" ]; then
        TRAP_RESTART=0
        echo -e "\e[93m♻️  Reiniciando após Ctrl+C...\e[0m"
    elif [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "130" ]; then
        # Exit clean (0) ou via SIGINT do próprio bot (130): restart curto.
        # O caso 0 cobre quando o bot trapou SIGINT e fez shutdown gracioso —
        # cenário em que a trap do supervisor não disparou (Ctrl+C foi
        # consumido só pelo bot) mas queremos reiniciar imediatamente.
        echo -e "\e[93m♻️  Bot encerrou (code=$EXIT_CODE). Reiniciando...\e[0m"
        sleep 0.3
    else
        echo -e "\e[91m⚠️  Bot crashou (code=$EXIT_CODE). Reiniciando em 1s...\e[0m"
        sleep 1
    fi
done

rm -f "$PID_FILE"
echo -e "\e[92m✅ Bot encerrado.\e[0m"
