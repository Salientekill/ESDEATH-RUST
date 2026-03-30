#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== ESDEATH BOT - Setup Inicial ==="

# 1. Cria estrutura de diretorios
echo "Criando estrutura de diretorios..."
mkdir -p "$SCRIPT_DIR/dados/DB"
mkdir -p "$SCRIPT_DIR/dados/org/json"
mkdir -p "$SCRIPT_DIR/esdeath"
mkdir -p "$SCRIPT_DIR/logs"

# 2. Baixa o binario (via atualizar.sh)
echo "Baixando binario..."
bash "$SCRIPT_DIR/atualizar.sh"

# 3. Cria bot_config.json a partir do template (se nao existe)
CONFIG="$SCRIPT_DIR/dados/bot_config.json"
TEMPLATE="$SCRIPT_DIR/esdeath/bot_config.json.template"

if [ ! -f "$CONFIG" ] && [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$CONFIG"
    echo "bot_config.json criado em dados/. Edite com suas configuracoes."
elif [ ! -f "$CONFIG" ]; then
    echo "AVISO: Template de config nao encontrado. O bot criara um padrao ao iniciar."
fi

# 4. Instrucoes finais
echo ""
echo "========================================="
echo "  Setup completo!"
echo "========================================="
echo ""
echo "Proximos passos:"
echo "  1. Coloque seu chave.dat em dados/"
echo "     (recebido do desenvolvedor)"
echo ""
echo "  2. Edite dados/bot_config.json"
echo "     (nome do bot, prefixo, etc.)"
echo ""
echo "  3. Inicie o bot:"
echo "     bash start.sh"
echo ""
echo "Para atualizar no futuro:"
echo "     bash atualizar.sh"
echo "========================================="
