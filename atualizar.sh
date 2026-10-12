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

# Os testes (tests/scripts/atualizacao.sh) carregam só as funções acima.
if [ "${ESDEATH_SO_FUNCOES:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

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

    # Na pasta do bot, não no /tmp: em painel (Pterodactyl) o /tmp do container
    # é pequeno ou fora da cota, e o clone do repo público estoura (os error 28).
    TMPDIR=$(mktemp -d "$SCRIPT_DIR/.atualizar.XXXXXX")
    # shellcheck disable=SC2064  # expandir AGORA é o certo: o `mktemp -d` está
    # na linha acima, e adiar deixaria o trap com `rm -rf` vazio se a variável
    # sumisse no caminho.
    trap "rm -rf $TMPDIR" EXIT

    echo "Baixando atualizacao${TARGET_TAG:+ (tag $TARGET_TAG)}..."
    if [ -n "$TARGET_TAG" ]; then
        git clone --depth 1 --branch "$TARGET_TAG" "$PUBLIC_REPO" "$TMPDIR/pub" --quiet \
            || { echo "ERRO: falha ao clonar a tag $TARGET_TAG."; exit 1; }
    else
        git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet \
            || { echo "ERRO: falha ao clonar repositorio."; exit 1; }
    fi

    if [ ! -f "$TMPDIR/pub/esdeath/esdeath-bot" ]; then
        echo "ERRO: binario nao encontrado no repositorio."
        exit 1
    fi
    conferir_assinatura "$TMPDIR/pub" || exit 1

    # Copia via rename atômico para evitar ETXTBSY em containers
    # (cp direto sobre binário em execução falha em alguns ambientes)
    TMP_BIN="${BIN}.new.$$"
    cp "$TMPDIR/pub/esdeath/esdeath-bot" "$TMP_BIN"
    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$BIN"

    # Copia scripts atualizados
    instalar_script "$TMPDIR/pub/start.sh" "$SCRIPT_DIR/start.sh" || true
    instalar_script "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh" || true
    instalar_script "$TMPDIR/pub/setup.sh" "$SCRIPT_DIR/setup.sh" || true

    [ -f "$TMPDIR/pub/esdeath/bot_config.json.template" ] && \
        cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template" 2>/dev/null || true

    mesclar_dados

    [ -f "$TMPDIR/pub/.version" ] && cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"

    NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
    marcar_em_teste
    echo "Atualizado: $CURRENT -> $NEW"

    # Mata só o binário do bot (supervisor continua vivo e relança).
    # Delay pra dar tempo da mensagem ser enviada antes do kill.
    # Sem herdar o stdout: o bot lê a saída deste script até o EOF, e com o
    # subshell segurando o pipe ele só voltaria depois do próprio SIGTERM.
    (sleep 2 && stop_bot_bin_only) >/dev/null 2>&1 &
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

echo "Baixando atualizacao${TARGET_TAG:+ (tag $TARGET_TAG)}..."
TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064  # expandir AGORA é o certo: o `mktemp -d` está na
# linha acima, e adiar deixaria o trap com `rm -rf` vazio se a variável sumisse.
trap "rm -rf $TMPDIR" EXIT

if [ -n "$TARGET_TAG" ]; then
    git clone --depth 1 --branch "$TARGET_TAG" "$PUBLIC_REPO" "$TMPDIR/pub" --quiet \
        || { echo "ERRO: falha ao clonar a tag $TARGET_TAG (git instalado e rede ok?)."; exit 1; }
else
    git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet \
        || { echo "ERRO: falha ao clonar repositorio (git instalado e rede ok?)."; exit 1; }
fi

if [ ! -f "$TMPDIR/pub/esdeath/esdeath-bot" ]; then
    echo "ERRO: binario nao encontrado no repositorio."
    exit 1
fi
conferir_assinatura "$TMPDIR/pub" || exit 1

# Rename atômico: evita ETXTBSY com binário em uso
TMP_BIN="${BIN}.new.$$"
cp "$TMPDIR/pub/esdeath/esdeath-bot" "$TMP_BIN"
chmod +x "$TMP_BIN"
mv "$TMP_BIN" "$BIN"

# Scripts e template (best-effort)
instalar_script "$TMPDIR/pub/start.sh" "$SCRIPT_DIR/start.sh" || true
instalar_script "$TMPDIR/pub/atualizar.sh" "$SCRIPT_DIR/atualizar.sh" || true
instalar_script "$TMPDIR/pub/setup.sh" "$SCRIPT_DIR/setup.sh" || true
[ -f "$TMPDIR/pub/esdeath/bot_config.json.template" ] && \
    cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template" 2>/dev/null || true

mesclar_dados

[ -f "$TMPDIR/pub/.version" ] && cp "$TMPDIR/pub/.version" "$SCRIPT_DIR/.version"

NEW=$(cat "$SCRIPT_DIR/.version" 2>/dev/null || echo "desconhecida")
marcar_em_teste
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
