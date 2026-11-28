#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Os caminhos do bot (dados/, credenciais.json, apikey.enc) são relativos.
cd "$SCRIPT_DIR" || exit 1
PID_FILE="$SCRIPT_DIR/.bot.pid"
# Um binário por arquitetura, os dois na pasta `esdeath/`, e a escolha é feita
# aqui a cada partida: quem leva a pasta de um x86 para um ARM (ou o contrário)
# segue funcionando. O nome é igual nos dois lados: é como o asset sai da
# release pública e como o binário se chama aqui.
case "$(uname -m)" in
    aarch64 | arm64)
        MUSL_TARGET="aarch64-unknown-linux-musl"
        BIN_NAME_PUB="esdeath-bot-aarch64"
        ;;
    x86_64 | amd64)
        MUSL_TARGET="x86_64-unknown-linux-musl"
        BIN_NAME_PUB="esdeath-bot"
        ;;
    *)
        # armv7l/armv8l (sistema 32 bits) caía no x86 e reiniciava sem fim
        # com "Exec format error".
        echo "❌ Arquitetura $(uname -m) não suportada (o bot roda em x86_64 e ARM64 de 64 bits)."
        exit 1
        ;;
esac
DB="${BOT_DB_PATH:-"$SCRIPT_DIR/dados/DB/ESDEATH_AUTH.db"}"

# ── Detecta binário: comp2 (debug nativo) > comp (musl release) > pub ──────
DEV_BIN="$SCRIPT_DIR/target/$MUSL_TARGET/release/esdeath-bot"
DBG_BIN="$SCRIPT_DIR/target/debug/esdeath-bot"
PUB_BIN="$SCRIPT_DIR/esdeath/$BIN_NAME_PUB"
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

# ── Rollback automático e freio de laço (atualização automática) ─────────────
# O `atualizar.sh` deixa `.backups/em_teste` (de/para/quedas) ao trocar o
# binário. Enquanto a marca existir, TODA saída da versão nova conta (até a de
# código 0: um binário que sai limpo no boot também está quebrado); na 3ª, ela é
# dada como ruim: volta o binário anterior, a versão entra em `.backups/ruins`
# (a atualização automática nunca a reinstala) e `.backups/rollback_feito` fica
# para o bot avisar o dono. O bot apaga `em_teste` depois de 3 min de pé, sem
# depender de conectar ao WhatsApp.
BACKUPS="$SCRIPT_DIR/.backups"
EM_TESTE="$BACKUPS/em_teste"
QUEDAS_PARA_VOLTAR=3

# pgrep/pkill -f tratam o argumento como regex: o caminho vai escapado (pasta
# com `.`, `+` ou `(` casaria com processo alheio). Mesma função do atualizar.sh.
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

campo_em_teste() { sed -n "s/^$1=//p" "$EM_TESTE" 2>/dev/null | head -1 | tr -d '\r'; }

# $1 = versão que estava rodando (o `.version` lido ANTES de lançar): a saída
# do binário velho na própria troca não pode contar contra o novo. Só mexe no
# binário publicado (PUB_BIN): build local do dono nunca é trocado por aqui.
voltar_versao_se_preciso() {
    local lancada="$1" de para quedas antigo
    [ -f "$EM_TESTE" ] || return 0
    de=$(campo_em_teste de); para=$(campo_em_teste para); quedas=$(campo_em_teste quedas)
    [ -n "$para" ] && [ "$lancada" = "$para" ] || return 0
    case "$quedas" in ''|*[!0-9]*) quedas=0 ;; esac
    quedas=$(( quedas + 1 ))
    if [ "$quedas" -lt "$QUEDAS_PARA_VOLTAR" ]; then
        printf 'de=%s\npara=%s\nquedas=%s\n' "$de" "$para" "$quedas" > "$EM_TESTE"
        return 0
    fi
    antigo="$BACKUPS/$BIN_NAME_PUB.$de"
    rm -f "$EM_TESTE"
    if [ "$BOT_BIN" != "$PUB_BIN" ] || [ ! -f "$antigo" ]; then
        echo -e "\e[91m⚠️  A versão $para caiu $quedas vezes ao iniciar e não há binário anterior para voltar.\e[0m"
        return 0
    fi
    if ! { cp "$antigo" "$PUB_BIN.volta.$$" && chmod +x "$PUB_BIN.volta.$$" && mv "$PUB_BIN.volta.$$" "$PUB_BIN"; }; then
        rm -f "$PUB_BIN.volta.$$"
        echo -e "\e[91m⚠️  A versão $para caiu $quedas vezes, mas não consegui voltar o binário da $de.\e[0m"
        return 0
    fi
    echo "$de" > "$SCRIPT_DIR/.version"
    echo "$para" >> "$BACKUPS/ruins"
    printf 'de=%s\npara=%s\nts=%s\n' "$para" "$de" "$(date +%s)" > "$BACKUPS/rollback_feito"
    echo -e "\e[93m↩️  A versão $para caiu $quedas vezes ao iniciar: voltei para $de.\e[0m"
}

# Freio geral: a partir de 5 saídas em 3 h, a espera dobra a cada saída (60 s,
# 2 min, 4 min… até 30 min), em vez de $1. Janela curta não pegava o bot que cai
# a cada 3 min: virava login no WhatsApp 20 vezes por hora, sem fim. Vale para
# toda volta do laço (saída 0 em laço também é laço). Deixa a espera em
# $ESPERA: chamar com `$(...)` rodaria num subshell e a lista nunca cresceria.
QUEDAS_RECENTES=""
SAIDAS_LIMPAS=""
ESPERA=1
# $2 = "limpa" para saída pedida (0/130: !reiniciar, atualização). Ela não entra
# no freio longo — reinício pedido não é queda — e só tem o freio curto antigo
# (5 em 5 min → 60 s), que segura um laço de saída 0.
espera_depois_da_queda() {
    local base="${1:-1}" agora t novas="" n=0 janela=10800 lista="$QUEDAS_RECENTES"
    agora=$(date +%s)
    [ "${2:-}" = "limpa" ] && { janela=300; lista="$SAIDAS_LIMPAS"; }
    for t in $lista $agora; do
        if [ $(( agora - t )) -lt "$janela" ]; then novas="$novas $t"; n=$(( n + 1 )); fi
    done
    if [ "${2:-}" = "limpa" ]; then
        SAIDAS_LIMPAS="$novas"
        if [ "$n" -ge 5 ]; then ESPERA=60; else ESPERA="$base"; fi
        return 0
    fi
    QUEDAS_RECENTES="$novas"
    if [ "$n" -ge 5 ]; then
        ESPERA=$(( 60 << (n - 5 > 5 ? 5 : n - 5) ))
        [ "$ESPERA" -gt 1800 ] && ESPERA=1800
    else
        ESPERA="$base"
    fi
}

# Os testes (tests/scripts/atualizacao.sh) carregam só as funções acima.
if [ "${ESDEATH_SO_FUNCOES:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
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
# $1 = alvo (padrão: o desta máquina).
musl_build() {
    local alvo="${1:-$MUSL_TARGET}" pagina=()
    ensure_zig || return 1
    # Compilado em outra máquina, o jemalloc fixa a página de 4 KB, e servidor
    # ARM com página de 64 KB derruba o bot ao ligar. 64 KB (2^16) serve aos dois.
    case "$alvo" in aarch64-*) pagina=(JEMALLOC_SYS_WITH_LG_PAGE=16) ;; esac
    # Protege os bots em produção (mesmo servidor, 4 cores): `nice -n 19` cede CPU
    # pros bots; `-j 2` + CMAKE limitado usam no máx ~2 cores, deixando 2 livres —
    # evita saturar a CPU e causar latência/desconexão dos bots durante o build.
    # O jemalloc é padrão no Cargo.toml: `comp jemalloc` ainda é aceito, mas
    # não muda nada.
    # `nice` cede CPU, mas NÃO cede prioridade de I/O — e o gargalo medido em
    # 21/08 foi disco, não CPU: o rustc empurrou o page cache do SQLite pra fora
    # e um `db.run` levou 56s. `ionice -c3` (classe idle) faz o build só usar
    # disco quando ninguém mais quer.
    env ${pagina[@]+"${pagina[@]}"} CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" nice -n 19 ionice -c3 \
        cargo zigbuild --release --target "$alvo" -j "${BUILD_JOBS:-2}" \
        --manifest-path "$SCRIPT_DIR/Cargo.toml"
}

case "${1:-}" in
    comp)
        # comp       -> build de producao com jemalloc (RSS desce via decay).
        # comp arm   -> o mesmo para servidor ARM (target/aarch64-unknown-linux-musl).
        # comp x86   -> o mesmo para x86, compilando de um ARM.
        case "${2:-}" in
            arm) musl_build aarch64-unknown-linux-musl ;;
            x86) musl_build x86_64-unknown-linux-musl ;;
            *) musl_build ;;
        esac
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
            cargo zigbuild --profile profiling --no-default-features --features dhat-heap \
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
    sync|sincronizar)
        # Põe o bot de dev na MESMA build que o cliente recebeu.
        #
        # Por que existe: o `release.sh` publica e não toca em nada aqui, e o
        # `comp` custa ~15 min disputando RAM e disco com os bots em produção.
        # Sem isto o binário local ia ficando pra trás a cada release — medido
        # em 29/08: repositório na v2.46, arquivo em disco na v2.45 e o processo
        # rodando um inode que nem existia mais no disco.
        #
        # A fonte é o asset da release PÚBLICA, e não o artefato do CI ou uma
        # compilação daqui: é literalmente o mesmo arquivo que o cliente baixa,
        # então testar contra ele é testar o que ele tem.
        command -v gh >/dev/null 2>&1 || { echo "ERRO: precisa do 'gh' autenticado." >&2; exit 1; }
        PUB_REPO="${PUBLIC_REPO:-Salientekill/ESDEATH-RUST}"
        TAG="${2:-}"
        if [ -z "$TAG" ]; then
            TAG=$(gh release view --repo "$PUB_REPO" --json tagName -q .tagName 2>/dev/null || echo "")
        fi
        [ -n "$TAG" ] || { echo "ERRO: não achei release em $PUB_REPO." >&2; exit 1; }

        TMP=$(mktemp -d) || exit 1
        trap 'rm -rf "$TMP"' EXIT
        echo "Baixando $TAG de $PUB_REPO..."
        if ! gh release download "$TAG" --repo "$PUB_REPO" --pattern "$BIN_NAME_PUB" --dir "$TMP" 2>&1; then
            echo "ERRO: download falhou." >&2; exit 1
        fi
        chmod +x "$TMP/$BIN_NAME_PUB"

        # Valida ANTES de substituir: um binário que não executa viraria um bot
        # que não sobe, e o supervisor ficaria em loop de crash.
        VER=$("$TMP/$BIN_NAME_PUB" --version 2>&1 | head -1) || {
            echo "ERRO: o binário baixado não executa aqui." >&2; exit 1; }
        echo "  $VER"

        mkdir -p "$SCRIPT_DIR/.backups"
        if [ -f "$DEV_BIN" ]; then
            ANTES=$("$DEV_BIN" --version 2>&1 | head -1 || echo "?")
            # Nome = VERSÃO, não timestamp: é assim que o `atualizar.sh` do
            # cliente grava e é de onde o `rollback` tira o `.version`. Com
            # timestamp o rollback anunciaria "revertido para 20260829-130041".
            ANTES_V=$(echo "$ANTES" | awk '{print $NF}')
            [ -n "$ANTES_V" ] || ANTES_V="desconhecida"
            cp "$DEV_BIN" "$SCRIPT_DIR/.backups/$BIN_NAME_PUB.${ANTES_V}" 2>/dev/null || true
            # Retém só a versão anterior (~24 MB): o container do cliente é pequeno.
            ls -t "$SCRIPT_DIR/.backups"/"$BIN_NAME_PUB".* 2>/dev/null | tail -n +2 \
                | xargs rm -f 2>/dev/null || true
            echo "  substituindo: $ANTES"
        fi
        mkdir -p "$(dirname "$DEV_BIN")"
        # `mv` e não `cp`: escrever por cima de um binário EM EXECUÇÃO devolve
        # ETXTBSY. O rename troca o nome, o processo antigo segue no inode
        # antigo (é o `(deleted)` que aparece em /proc/<pid>/exe) e some quando
        # ele sair.
        mv -f "$TMP/$BIN_NAME_PUB" "$DEV_BIN" || { echo "ERRO: não deu pra instalar." >&2; exit 1; }
        chmod +x "$DEV_BIN"

        # O `start.sh` é supervisor: reexecuta o CAMINHO a cada volta do loop.
        # Derrubar só o processo do BOT faz ele subir já na versão nova, sem
        # matar o supervisor nem exigir que alguém rode o start de novo.
        if pgrep -f "$(re_escape "$DEV_BIN")" >/dev/null 2>&1; then
            echo "  reiniciando o bot (o supervisor sobe a versão nova)..."
            pkill -f "$(re_escape "$DEV_BIN")" 2>/dev/null || true
        else
            echo "  bot não está rodando — sobe na próxima vez que você iniciar."
        fi
        echo "Pronto: $TAG"
        exit 0
        ;;
    rollback)
        BACKUP_DIR="$SCRIPT_DIR/.backups"
        BACKUP=$(ls -t "$BACKUP_DIR"/"$BIN_NAME_PUB".* 2>/dev/null | head -1)
        if [ -z "$BACKUP" ]; then
            echo "Nenhum backup encontrado."
            exit 1
        fi
        # Destino é o binário EM USO, não um caminho fixo. Numa instalação de
        # cliente é o `esdeath/`; aqui na dev é o `target/`, e restaurar no
        # `esdeath/` criava um arquivo que ninguém executa — o rollback dizia
        # "revertido" e o bot seguia na versão nova.
        if [ -f "$DEV_BIN" ]; then ALVO="$DEV_BIN"; else ALVO="$PUB_BIN"; fi
        # `cp` por cima de binário EM EXECUÇÃO devolve ETXTBSY, e como este
        # script não roda com `set -e` o erro passava batido e o "Revertido"
        # saía mesmo sem nada ter mudado. Escreve ao lado e renomeia.
        if ! cp "$BACKUP" "$ALVO.tmp" || ! mv -f "$ALVO.tmp" "$ALVO"; then
            rm -f "$ALVO.tmp"
            echo "ERRO: não deu pra restaurar em $ALVO" >&2
            exit 1
        fi
        chmod +x "$ALVO"
        VERSION=$(basename "$BACKUP")
        VERSION="${VERSION#"$BIN_NAME_PUB".}"
        ABANDONADA=$(cat "$SCRIPT_DIR/.version" 2>/dev/null)
        echo "$VERSION" > "$SCRIPT_DIR/.version"
        # Mesmo registro do `atualizar.sh rollback`: sem a versão desfeita em
        # `ruins`, a atualização automática a reinstalava na hora seguinte.
        rm -f "$BACKUP_DIR/em_teste"
        if [ -n "$ABANDONADA" ] && [ "$ABANDONADA" != "$VERSION" ] \
            && ! grep -qxF "$ABANDONADA" "$BACKUP_DIR/ruins" 2>/dev/null; then
            echo "$ABANDONADA" >> "$BACKUP_DIR/ruins" || echo "AVISO: não deu pra marcar $ABANDONADA como ruim."
        fi
        echo "Revertido para $VERSION ($ALVO)"
        # Sem isto o arquivo volta e o processo continua no que já estava
        # carregado — reverter sem reiniciar não reverte nada.
        if pgrep -f "$(re_escape "$ALVO")" >/dev/null 2>&1; then
            echo "  reiniciando o bot..."
            pkill -f "$(re_escape "$ALVO")" 2>/dev/null || true
        fi
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
        # Só apaga depois de derrubar a instância anterior (abaixo): apagar com o
        # bot de pé deixa ele vivo e mudo, gravando num banco vazio.
        RESET_SESSAO=1
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
                # O dhat só é o alocador sem o jemalloc, que é padrão.
                SEM_PADRAO=()
                [ "$2" = "dhat" ] && FEAT="dhat-heap" && SEM_PADRAO=(--no-default-features)
                ensure_zig || exit 1
                echo "Buildando profiling ($2, feature $FEAT)..."
                CMAKE_BUILD_PARALLEL_LEVEL="${BUILD_JOBS:-2}" nice -n 19 \
                    cargo zigbuild --profile profiling ${SEM_PADRAO[@]+"${SEM_PADRAO[@]}"} --features "$FEAT" \
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
        echo "Uso: bash start.sh [comp|comp2|recomp|sync|dhat|ram|clean|update|rollback|debug|debug2|reset]"
        echo "     comp [arm|x86] = compila (sem arg: para esta máquina)"
        echo "     sync [tag] = baixa a release publicada e reinicia o bot nela"
        echo "     ram [dhat|jemalloc] = builda o profiler e roda (default jemalloc)"
        exit 1
        ;;
esac

# Verifica se o binário existe
if [ -z "$BOT_BIN" ]; then
    if [ -f "$SCRIPT_DIR/esdeath/esdeath-bot" ] && [ "$BIN_NAME_PUB" != "esdeath-bot" ]; then
        # Pasta trazida de um x86 com uma versão anterior aos dois binários.
        echo "Esta máquina é ARM ($(uname -m)) e a versão instalada só tem o bot para x86."
        echo "Atualize para uma versão com suporte a ARM: bash setup.sh"
    elif [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
        echo "Binario nao encontrado. Compile com: bash start.sh comp"
    else
        echo "Binario nao encontrado. Execute: bash setup.sh"
    fi
    exit 1
fi

# Binário sem permissão de execução (code=126): acontece quando o arquivo é enviado
# ou extraído pelo gerenciador de arquivos do painel, que grava sem o bit +x.
if [ ! -x "$BOT_BIN" ]; then
    chmod +x "$BOT_BIN" 2>/dev/null || true
    if [ ! -x "$BOT_BIN" ]; then
        echo "ERRO: $BOT_BIN está sem permissão de execução e não deu para corrigir."
        echo "No gerenciador de arquivos do painel, abra as permissões dele e marque 755."
        exit 1
    fi
    echo "Permissão de execução do bot restaurada."
fi

# Painel e terminal podem rodar o start.sh ao mesmo tempo: a troca de instância
# (matar a anterior + gravar .bot.pid) é uma seção crítica. A trava só dura até o
# PID novo estar gravado; o supervisor em si continua sendo substituível. Sem
# `flock` (imagem mínima) segue sem trava, como o atualizar.sh.
if command -v flock >/dev/null 2>&1; then
    exec 8>"$SCRIPT_DIR/.start.trava"
    if ! flock -w 30 8; then
        echo "ERRO: outro start.sh está trocando a instância do bot; tente de novo."
        exit 1
    fi
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
            for _ in $(seq 1 10); do
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
    BIN_PATTERN=$(re_escape "$BIN_PATTERN")
    if pgrep -f "$BIN_PATTERN" >/dev/null 2>&1; then
        echo "Fechando instancias orfas ($BIN_PATTERN)..."
        pkill -f "$BIN_PATTERN" 2>/dev/null || true
        sleep 2
        pkill -9 -f "$BIN_PATTERN" 2>/dev/null || true
    fi
done

if [ "${RESET_SESSAO:-}" = 1 ]; then
    rm -f "$DB" "$DB-shm" "$DB-wal"
    echo "Sessao removida. Reconectando..."
fi

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
        # O shutdown gracioso do bot (disconnect com teto de 5 s no app::run,
        # flush do log, checkpoint do WAL) leva alguns segundos: 1 s de espera
        # matava com KILL no meio dele. 15 s é o teto antes do KILL.
        for _ in $(seq 1 60); do
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
    [ -n "$DORMIR_PID" ] && kill "$DORMIR_PID" 2>/dev/null
    stop_bot
}

# `sleep` em primeiro plano segura a trap até terminar (até 1 h no ban): em
# segundo plano com `wait`, o bash trata o sinal na hora.
DORMIR_PID=""
dormir() {
    sleep "$1" &
    DORMIR_PID=$!
    wait "$DORMIR_PID" 2>/dev/null
    kill "$DORMIR_PID" 2>/dev/null
    DORMIR_PID=""
}

trap on_sigint  INT
trap on_sigtstp TSTP
trap on_sigterm TERM

# Sinal que chega IGNORADO na entrada do shell não pode ser trapado: o bash
# recusa e não diz nada ("Signals ignored upon entry to the shell cannot be
# trapped or reset", man bash). Acontece quando quem chamou este script rodou
# `trap "" SIGINT` — um wrapper de `screen`, por exemplo —, e o efeito é o
# Ctrl+C simplesmente não fazer nada: nem o restart, nem o duplo que encerra.
#
# Sem esta checagem a falha é invisível: as três linhas acima "passam", o
# cabeçalho segue anunciando os atalhos, e nenhum deles funciona.
if [ "$(trap -p INT)" = "trap -- '' SIGINT" ]; then
    echo -e "\e[91m⚠️  SIGINT chegou IGNORADO: Ctrl+C não vai funcionar aqui.\e[0m"
    echo -e "\e[93m    Quem iniciou este script rodou \`trap '' SIGINT\`, e o bash não\e[0m"
    echo -e "\e[93m    deixa instalar handler pra sinal ignorado na entrada.\e[0m"
    echo -e "\e[93m    Inicie sem ele:  screen -dmS esdeath bash -c 'cd ~/nrust && bash start.sh'\e[0m"
    echo -e "\e[93m    Encerrar agora:  kill $$\e[0m"
fi

# jemalloc (build `comp jemalloc`): decay devolve memoria liberada pro SO -> a
# RSS desce apos picos de midia. Ignorado por build nao-jemalloc. `ram` ja setou
# o seu (prof), entao `:-` preserva. A producao usa o jemalloc com prefixo
# (desde a 3.45), que so le `_RJEM_MALLOC_CONF`; o `jemalloc-prof` le MALLOC_CONF.
export MALLOC_CONF="${MALLOC_CONF:-background_thread:true,dirty_decay_ms:5000,muzzy_decay_ms:5000}"
export _RJEM_MALLOC_CONF="${_RJEM_MALLOC_CONF:-$MALLOC_CONF}"

# PID do supervisor (quem mata este PID encerra tudo via trap TERM)
echo "$$" > "$PID_FILE"
exec 8>&-

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
    LANCADA=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || true)
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
    elif [ "$EXIT_CODE" = "75" ]; then
        # Outra cópia do bot com o mesmo número (ou nesta pasta). Religar na hora
        # derrubava a outra, que derrubava esta: o vai-e-volta leva a ban.
        echo -e "\e[91m⚠️  Outra cópia do bot está usando este número. Desligue-a. Tentando de novo em 5 min...\e[0m"
        dormir 300
    elif [ "$EXIT_CODE" = "76" ]; then
        # Ban temporário: conectar durante o ban só piora. Espera o prazo do servidor.
        ESPERA_BAN=$(cat dados/.espera_ban 2>/dev/null || echo 3600)
        rm -f dados/.espera_ban
        case "$ESPERA_BAN" in ''|*[!0-9]*) ESPERA_BAN=3600 ;; esac
        [ "$ESPERA_BAN" -gt 86400 ] && ESPERA_BAN=86400
        [ "$ESPERA_BAN" -lt 60 ] && ESPERA_BAN=60
        echo -e "\e[91m⛔ Ban temporário. Religando em $((ESPERA_BAN / 60)) min...\e[0m"
        dormir "$ESPERA_BAN"
    elif [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "130" ]; then
        # Exit clean (0) ou via SIGINT do próprio bot (130): restart curto.
        # O caso 0 cobre quando o bot trapou SIGINT e fez shutdown gracioso —
        # cenário em que a trap do supervisor não disparou (Ctrl+C foi
        # consumido só pelo bot) mas queremos reiniciar imediatamente.
        voltar_versao_se_preciso "$LANCADA"
        espera_depois_da_queda 0.3 limpa
        echo -e "\e[93m♻️  Bot encerrou (code=$EXIT_CODE). Reiniciando...\e[0m"
        dormir "$ESPERA"
    else
        voltar_versao_se_preciso "$LANCADA"
        espera_depois_da_queda 1
        echo -e "\e[91m⚠️  Bot crashou (code=$EXIT_CODE). Reiniciando em ${ESPERA}s...\e[0m"
        dormir "$ESPERA"
    fi
done

rm -f "$PID_FILE"
echo -e "\e[92m✅ Bot encerrado.\e[0m"
