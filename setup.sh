#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_REPO="https://github.com/Salientekill/ESDEATH-RUST.git"

echo "========================================"
echo "  ESDEATH BOT — Setup Inicial"
echo "========================================"
echo ""

# ── 1. Baixa arquivos do repo público se faltarem ──────────────────────────
if [ ! -f "$SCRIPT_DIR/esdeath/esdeath-bot" ]; then
    echo "[1/4] Baixando arquivos do repo público..."
    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT
    git clone --depth 1 "$PUBLIC_REPO" "$TMPDIR/pub" --quiet
    # Copia binário e scripts
    mkdir -p "$SCRIPT_DIR/esdeath"
    cp "$TMPDIR/pub/esdeath/esdeath-bot" "$SCRIPT_DIR/esdeath/esdeath-bot"
    cp "$TMPDIR/pub/esdeath/bot_config.json.template" "$SCRIPT_DIR/esdeath/bot_config.json.template"
    chmod +x "$SCRIPT_DIR/esdeath/esdeath-bot"
    # Copia scripts da raiz se não existirem
    for f in start.sh atualizar.sh; do
        [ ! -f "$SCRIPT_DIR/$f" ] && cp "$TMPDIR/pub/$f" "$SCRIPT_DIR/$f" && chmod +x "$SCRIPT_DIR/$f"
    done
    echo "      Arquivos baixados."
    echo ""
else
    echo "[1/4] Arquivos já presentes (pulando download)."
    echo ""
fi

# ── 2. Cria estrutura de diretórios ─────────────────────────────────────────
echo "[2/4] Criando estrutura de diretórios..."
mkdir -p "$SCRIPT_DIR/dados/DB"
mkdir -p "$SCRIPT_DIR/dados/org/json"
mkdir -p "$SCRIPT_DIR/logs"
echo ""

# ── 3. Configuração interativa do bot_config.json ──────────────────────────
CONFIG="$SCRIPT_DIR/dados/bot_config.json"
TEMPLATE="$SCRIPT_DIR/esdeath/bot_config.json.template"

echo "[3/4] Configurando bot_config.json..."
if [ -f "$CONFIG" ]; then
    echo "      Config já existe em dados/bot_config.json (pulando)."
    echo ""
else
    if [ ! -f "$TEMPLATE" ]; then
        echo "      ERRO: Template não encontrado em $TEMPLATE"
        exit 1
    fi

    echo ""
    echo "  Preencha os dados do bot:"
    echo ""

    read -p "  Nome do bot [ESDEATH BOT]: " BOT_NAME
    BOT_NAME="${BOT_NAME:-ESDEATH BOT}"

    read -p "  Prefixo dos comandos [!]: " BOT_PREFIX
    BOT_PREFIX="${BOT_PREFIX:-!}"

    read -p "  Número do dono (ex: 5511999999999): " BOT_OWNER
    while [ -z "$BOT_OWNER" ]; do
        echo "  Número do dono é obrigatório."
        read -p "  Número do dono: " BOT_OWNER
    done
    # Limpa caracteres não-numéricos
    BOT_OWNER=$(echo "$BOT_OWNER" | tr -cd '0-9')

    read -p "  Emoji do tema [❄️]: " BOT_EMOJI
    BOT_EMOJI="${BOT_EMOJI:-❄️}"

    # Gera config a partir do template substituindo os campos
    python3 -c "
import json, sys
with open('$TEMPLATE', 'r') as f:
    cfg = json.load(f)
cfg['name'] = '''$BOT_NAME'''
cfg['prefix'] = '''$BOT_PREFIX'''
cfg['owner'] = '''$BOT_OWNER'''
cfg['emoji'] = '''$BOT_EMOJI'''
with open('$CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
        # Fallback sem python: usa sed
        cp "$TEMPLATE" "$CONFIG"
        sed -i "s|\"name\": \".*\"|\"name\": \"$BOT_NAME\"|" "$CONFIG"
        sed -i "s|\"prefix\": \".*\"|\"prefix\": \"$BOT_PREFIX\"|" "$CONFIG"
        sed -i "s|\"owner\": \".*\"|\"owner\": \"$BOT_OWNER\"|" "$CONFIG"
        sed -i "s|\"emoji\": \".*\"|\"emoji\": \"$BOT_EMOJI\"|" "$CONFIG"
    }

    echo ""
    echo "      Config salvo em dados/bot_config.json"
    echo ""
fi

# ── 4. Verificar chave ──────────────────────────────────────────────────────
echo "[4/4] Verificando chave de acesso..."
if [ -f "$SCRIPT_DIR/dados/chave.dat" ] || [ -f "$SCRIPT_DIR/dados/chave.txt" ]; then
    echo "      Chave encontrada."
    KEY_OK=1
else
    KEY_OK=0
fi

echo ""
echo "========================================"
echo "  Setup completo!"
echo "========================================"
echo ""

if [ "$KEY_OK" = "0" ]; then
    echo "  ⚠️  FALTA APENAS 1 PASSO:"
    echo ""
    echo "     Coloque a chave de acesso em:"
    echo "        dados/chave.dat"
    echo ""
    echo "     (você recebeu do desenvolvedor)"
    echo ""
    echo "  Depois execute:"
    echo "     bash start.sh"
else
    echo "  Tudo pronto! Inicie o bot com:"
    echo "     bash start.sh"
fi
echo ""
echo "  Para atualizar no futuro:"
echo "     bash atualizar.sh"
echo "========================================"
