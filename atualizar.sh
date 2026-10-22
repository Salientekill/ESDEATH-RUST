#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.bot.pid"
BIN="$SCRIPT_DIR/esdeath/esdeath-bot"

# Manifesto assinado da release (esdeath/manifesto + .sig): versão e sha256 de
# TUDO o que veio no clone. Quem confere é o binário que está rodando AGORA: a
# chave pública mora nele, e nada do clone merece confiança ainda.
#
# A decisão de conferir vem do `.version` instalado, não de executar o binário:
# a partir da 3.31 qualquer falha (binário ausente, flag desconhecida, timeout)
# CANCELA a atualização. Abaixo da 3.31 o binário não conhece --verificar e,
# pior, trata flag desconhecida subindo o bot — então nem é chamado.
VERSAO_COM_VERIFICADOR="3.31"
instalada_confere() {
    local v
    v=$(printf '%s' "${CURRENT:-}" | sed 's/^v//' | grep -oE '^[0-9]+\.[0-9]+' || true)
    [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$VERSAO_COM_VERIFICADOR" "$v" | sort -V | head -1)" = "$VERSAO_COM_VERIFICADOR" ]
}
conferir_assinatura() {
    local pasta="$1" t=""
    if ! instalada_confere; then
        echo "AVISO: a versão instalada (${CURRENT:-?}) não confere assinatura; seguindo sem conferir."
        return 0
    fi
    command -v timeout >/dev/null 2>&1 && t="timeout 120"
    if (cd "$SCRIPT_DIR" && $t "$BIN" --verificar "$pasta" "$CURRENT"); then
        return 0
    fi
    echo "ERRO: a versão baixada não passou na conferência da assinatura — atualização cancelada, nada foi trocado."
    return 1
}

# A versão nova fica "em teste" até o bot passar 3 min de pé (ele apaga a
# marca); se cair 3 vezes antes disso, o start.sh volta para `de`. Marca velha
# de outra troca sai sempre; reinstalar a mesma versão não marca nada (o
# rollback acusaria como ruim a versão que está rodando).
marcar_em_teste() {
    # Recado de rollback de outra troca: o binário que o consumiria pode nem existir mais.
    rm -f "$SCRIPT_DIR/.backups/em_teste" "$SCRIPT_DIR/.backups/rollback_feito"
    [ "$CURRENT" != "$NEW" ] || return 0
    [ -f "$SCRIPT_DIR/.backups/esdeath-bot.$CURRENT" ] || return 0
    printf 'de=%s\npara=%s\nquedas=0\n' "$CURRENT" "$NEW" > "$SCRIPT_DIR/.backups/em_teste"
}

# Script novo entra por rename: o bash lê o script aos pedaços, e `cp` por cima
# faria este atualizar.sh (e o start.sh do supervisor) seguir no arquivo NOVO a
# partir do byte em que estava.
instalar_script() {
    [ -f "$1" ] || return 1
    cp "$1" "$2.new.$$" && chmod +x "$2.new.$$" && mv "$2.new.$$" "$2"
}

# Troca por rename: `cp` por cima do binário em uso dá "Text file busy" em
# alguns ambientes (containers).
trocar_binario() {
    cp "$1" "$BIN.new.$$" && chmod +x "$BIN.new.$$" && mv -f "$BIN.new.$$" "$BIN" && return 0
    rm -f "$BIN.new.$$"
    return 1
}

# Na pasta do bot, não no /tmp: em painel (Pterodactyl) o /tmp do container
# é pequeno ou fora da cota, e o clone do repo público estoura (os error 28).
# Aspas no trap: com espaço no caminho, `rm -rf $TMPDIR` apagaria OUTRA pasta.
criar_temporario() {
    # Sobra de atualização morta no meio (kill -9 não roda o trap): ~30 MB cada.
    find "$SCRIPT_DIR" -maxdepth 1 -name '.atualizar.??????' -type d -mmin +60 \
        -exec rm -rf -- {} + 2>/dev/null || true
    TMPDIR=$(mktemp -d "$SCRIPT_DIR/.atualizar.XXXXXX") || return 1
    trap 'rm -rf -- "$TMPDIR"' EXIT
}

# Uma atualização por vez: o bot (!atualizarbot, painel, automática) e alguém
# no terminal trocariam binário e .version ao mesmo tempo. Sem `flock` (imagem
# mínima) segue sem trava, como antes.
pegar_trava() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$SCRIPT_DIR/.atualizar.trava"
    flock -n 9 && return 0
    echo "ERRO: já há uma atualização em andamento; tente de novo em alguns minutos."
    return 1
}

# Em painel (Bronxys etc.) o .bot.pid sobrevive ao reinício do container com
# PID morto ou reciclado por outro processo; o próximo start.sh mataria esse.
limpar_pid_velho() {
    [ -f "$PID_FILE" ] || return 0
    local pid cmd
    pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "Limpando .bot.pid stale (PID $pid nao existe)."
        rm -f "$PID_FILE"
        return 0
    fi
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    if ! echo "$cmd" | grep -qE "esdeath-bot|start\.sh"; then
        echo "Limpando .bot.pid stale (PID $pid nao e do bot: $cmd)."
        rm -f "$PID_FILE"
    fi
}

# Dados JSON: soma o que falta, sem tocar no que o cliente editou.
#
# Antes, o arquivo era copiado só quando NÃO existia — o que preserva as
# edições dele, mas congela as nossas: quem já tinha rodado o bot uma vez nunca
# mais recebia brincadeira, frase ou resposta nova. O merge é aditivo e roda no
# binário, que sabe ler JSON: chave nova entra, chave existente fica com o
# valor do cliente. `mesclar_dados` cai no comportamento antigo se o binário
# for velho demais pra conhecer a flag.
mesclar_dados() {
    # Mídia: só entra o que falta — o cliente pode ter trocado um áudio ou uma
    # figurinha pelo dele, e o arquivo não tem como ser mesclado.
    for d in audios figs; do
        [ -d "$TMPDIR/pub/dados/midias/$d" ] || continue
        mkdir -p "$SCRIPT_DIR/dados/midias/$d"
        for f in "$TMPDIR/pub/dados/midias/$d/"*; do
            [ -e "$f" ] || continue
            dest="$SCRIPT_DIR/dados/midias/$d/$(basename "$f")"
            [ -e "$dest" ] || cp "$f" "$dest" || echo "   ! mídia $(basename "$f")"
        done
    done
    [ -d "$TMPDIR/pub/dados/org/json" ] || return 0
    mkdir -p "$SCRIPT_DIR/dados/org/json"
    # Jogos do !jogos: SOBRESCREVE os nossos, preserva os do cliente.
    #
    # Antes era add-only e isso congelava o catálogo: quem já tinha os arquivos
    # nunca recebia jogo corrigido — a mesma armadilha que o merge de configs
    # abaixo resolve, reintroduzida aqui. Como o cliente não edita jogo, o certo
    # é copiar por cima.
    #
    # Para saber o que é nosso sem manifesto, usamos a marca "HIURA" que o motor
    # escreve no cabeçalho de todo jogo que geramos. Arquivo com a marca e fora
    # do catálogo novo é jogo nosso aposentado -> some. Arquivo sem a marca é do
    # cliente -> fica. NÃO remover essa marca do motor.
    if [ -d "$TMPDIR/pub/dados/org/json/jogos" ]; then
        mkdir -p "$SCRIPT_DIR/dados/org/json/jogos"
        for f in "$SCRIPT_DIR/dados/org/json/jogos/"*.json; do
            [ -e "$f" ] || continue
            nome="$(basename "$f")"
            if [ ! -e "$TMPDIR/pub/dados/org/json/jogos/$nome" ]; then
                # `if` e não `&&`: sob `set -e` uma lista AND que termina em
                # falso derruba o script inteiro.
                if grep -q "HIURA" "$f" 2>/dev/null; then
                    rm -f "$f"
                    echo "   - jogo aposentado: $nome"
                fi
            fi
        done
        for f in "$TMPDIR/pub/dados/org/json/jogos/"*.json; do
            [ -e "$f" ] || continue
            cp -f "$f" "$SCRIPT_DIR/dados/org/json/jogos/" || echo "   ! jogo $(basename "$f")"
        done
    fi
    # `timeout` porque binário anterior à flag NÃO falha com um argumento que
    # não conhece — ele ignora e sobe o bot. Na distribuição normal script e
    # binário chegam juntos e isso não acontece, mas o custo do cinto é uma
    # linha e o de errar é uma atualização que nunca termina.
    _t=""
    command -v timeout >/dev/null 2>&1 && _t="timeout 120"
    if (cd "$SCRIPT_DIR" && $_t "$BIN" --mesclar-dados "$TMPDIR/pub/dados/org/json"); then
        return 0
    fi
    echo "   (merge indisponível: copiando só os arquivos ausentes)"
    for f in "$TMPDIR/pub/dados/org/json/"*.json; do
        [ -e "$f" ] || continue
        dest="$SCRIPT_DIR/dados/org/json/$(basename "$f")"
        [ -f "$dest" ] || cp "$f" "$dest" || echo "   ! não deu pra copiar $(basename "$f")"
    done
    # Dado é best-effort: quando esta função roda, o binário novo JÁ está no
    # lugar e o `.version` ainda não foi gravado. Sob `set -e`, um `cp` que
    # falhasse abortaria aqui e deixaria o cliente com binário novo e versão
    # antiga registrada — pior que ficar sem uma brincadeira.
    return 0
}
# Backup, download, conferência e troca — o caminho único dos modos `auto` e
# `update` (eram duas cópias, e a correção do temporário entrou só numa).
instalar_versao() {
    limpar_pid_velho
    if [ -f "$BIN" ]; then
        mkdir -p "$SCRIPT_DIR/.backups"
        # Explícito: chamada como `instalar_versao || exit`, a função roda sem
        # `set -e`, e trocar sem backup tiraria o caminho de volta.
        cp "$BIN" "$SCRIPT_DIR/.backups/esdeath-bot.${CURRENT}" \
            || { echo "ERRO: não consegui guardar o binário atual (disco cheio?)."; return 1; }
        ls -t "$SCRIPT_DIR/.backups"/esdeath-bot.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    fi
    criar_temporario || { echo "ERRO: não consegui criar a pasta temporária em $SCRIPT_DIR."; return 1; }
    echo "Baixando atualizacao${TARGET_TAG:+ (tag $TARGET_TAG)}..."
    local ramo=()
    [ -n "$TARGET_TAG" ] && ramo=(--branch "$TARGET_TAG")
    git clone --depth 1 ${ramo[@]+"${ramo[@]}"} "$PUBLIC_REPO" "$TMPDIR/pub" --quiet \
        || { echo "ERRO: falha ao baixar${TARGET_TAG:+ a tag $TARGET_TAG} (git instalado e rede ok?)."; return 1; }
    if [ ! -f "$TMPDIR/pub/esdeath/esdeath-bot" ]; then
        echo "ERRO: binario nao encontrado no repositorio."
        return 1
    fi
    conferir_assinatura "$TMPDIR/pub" || return 1
    trocar_binario "$TMPDIR/pub/esdeath/esdeath-bot" \
        || { echo "ERRO: não consegui trocar o binário (disco cheio?)."; return 1; }

    # Scripts e template (best-effort)
    instalar_script "$TMPDIR/pub/start.sh" "$SCRIPT_DIR/start.sh" || true
    instalar_script "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh" || true
    instalar_script "$TMPDIR/pub/setup.sh" "$SCRIPT_DIR/setup.sh" || true
    if [ -f "$TMPDIR/pub/esdeath/bot_config.json.template" ]; then
        cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template" 2>/dev/null || true
    fi

    mesclar_dados

    [ -f "$TMPDIR/pub/.version" ] && cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"
    NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
    marcar_em_teste
    echo "Atualizado: $CURRENT -> $NEW"
}

# A versão abandonada vira "ruim": sem isso a atualização automática a
# reinstalava na hora seguinte (o rollback automático do start.sh já marcava).
voltar_para() {
    local alvo="$1" backup="$SCRIPT_DIR/.backups/esdeath-bot.$1"
    if [ ! -f "$backup" ]; then
        echo "Backup '$alvo' não encontrado."
        return 1
    fi
    trocar_binario "$backup" || { echo "ERRO: não consegui trocar o binário."; return 1; }
    echo "$alvo" > "$SCRIPT_DIR/.version"
    rm -f "$SCRIPT_DIR/.backups/em_teste"
    if [ "$CURRENT" != "$alvo" ] && [ "$CURRENT" != "nenhuma" ] \
        && ! grep -qxF "$CURRENT" "$SCRIPT_DIR/.backups/ruins" 2>/dev/null; then
        echo "$CURRENT" >> "$SCRIPT_DIR/.backups/ruins"
    fi
}

# Os testes (tests/scripts/atualizacao.sh) carregam só as funções acima.
if [ "${ESDEATH_SO_FUNCOES:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

PUBLIC_REPO="https://github.com/Salientekill/ESDEATH-RUST.git"
MODE="${1:-update}"
# Tag alvo (ex: v1.138) passada pelo gate de versão do bot. Vazio = main (latest).
# Clonar a tag garante que um cliente do major 1 baixe o binário v1.x mesmo
# quando o main já está no v2.x — sem isso ele se brickaria (API rejeita EV2).
TARGET_TAG="${2:-}"

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
    pegar_trava || exit 1
    instalar_versao || exit 1

    # Mata só o binário do bot (supervisor continua vivo e relança).
    # Delay pra dar tempo da mensagem ser enviada antes do kill.
    # Sem herdar o stdout: o bot lê a saída deste script até o EOF, e com o
    # subshell segurando o pipe ele só voltaria depois do próprio SIGTERM.
    (sleep 2 && stop_bot_bin_only) >/dev/null 2>&1 9>&- &
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
    if [ ! -f "$BACKUP_DIR/esdeath-bot.${TARGET}" ]; then
        echo "Backup '$TARGET' não encontrado."
        exit 1
    fi

    echo ""
    read -p "Confirma rollback de $CURRENT → $TARGET? [s/N]: " CONFIRM
    if [ "${CONFIRM,,}" != "s" ]; then
        echo "Cancelado."
        exit 0
    fi

    pegar_trava || exit 1
    stop_bot
    voltar_para "$TARGET" || exit 1

    echo ""
    echo "Rollback para $TARGET concluído!"
    if [ "$CURRENT" != "$TARGET" ] && [ "$CURRENT" != "nenhuma" ]; then
        echo "A atualização automática não vai reinstalar a $CURRENT."
        echo "Para voltar a ela: atualizarbot force no privado do bot."
    fi
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
pegar_trava || exit 1
instalar_versao || exit 1
echo ""

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
