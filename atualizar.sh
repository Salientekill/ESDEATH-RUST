#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_OWNER="Salientekill"
REPO_NAME="ESDEATH-RUST"
BIN_NAME="esdeath-bot"
BIN_PATH="$SCRIPT_DIR/esdeath/$BIN_NAME"
VERSION_FILE="$SCRIPT_DIR/.version"
BACKUP_DIR="$SCRIPT_DIR/.backups"
PID_FILE="$SCRIPT_DIR/.bot.pid"

echo "=== ESDEATH BOT - Atualizador ==="

# 1. Busca ultima release no GitHub
echo "Verificando atualizacoes..."
LATEST=$(curl -sL "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)

if [ -z "$LATEST" ]; then
    echo "Erro: nao foi possivel verificar atualizacoes."
    echo "Verifique sua conexao com a internet."
    exit 1
fi

CURRENT=$(cat "$VERSION_FILE" 2>/dev/null || echo "nenhuma")
echo "Versao atual:        $CURRENT"
echo "Versao mais recente: $LATEST"

if [ "$CURRENT" = "$LATEST" ]; then
    echo "Voce ja esta na versao mais recente!"
    exit 0
fi

# 2. Para o bot se estiver rodando
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

# 3. Backup do binario atual
mkdir -p "$BACKUP_DIR"
if [ -f "$BIN_PATH" ]; then
    cp "$BIN_PATH" "$BACKUP_DIR/${BIN_NAME}.${CURRENT}"
    # Manter apenas ultimos 3 backups
    ls -t "$BACKUP_DIR"/${BIN_NAME}.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
fi

# 4. Download do novo binario
DOWNLOAD_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/$LATEST/${BIN_NAME}"
echo "Baixando $LATEST..."
curl -sL "$DOWNLOAD_URL" -o "$BIN_PATH.new"

# 5. Valida o binario
if ! file "$BIN_PATH.new" | grep -q "ELF 64-bit"; then
    echo "Erro: arquivo baixado nao e um binario valido."
    rm -f "$BIN_PATH.new"
    exit 1
fi

chmod +x "$BIN_PATH.new"
mv "$BIN_PATH.new" "$BIN_PATH"

# 6. Atualiza scripts/templates do repositorio
echo "Atualizando scripts..."
git -C "$SCRIPT_DIR" stash -q 2>/dev/null || true
git -C "$SCRIPT_DIR" pull --ff-only origin main 2>/dev/null || true
git -C "$SCRIPT_DIR" stash pop -q 2>/dev/null || true

# 7. Registra nova versao
echo "$LATEST" > "$VERSION_FILE"

echo ""
echo "Atualizado para $LATEST com sucesso!"
echo "Execute: bash start.sh"
