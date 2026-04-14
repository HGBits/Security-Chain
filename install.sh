#!/usr/bin/env bash
set -euo pipefail

REPO="HGBits/Security-Chain"
BRANCH="main"
RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

SCRIPT_NAME="rotina.zsh"
TMP_FILE="/tmp/$SCRIPT_NAME"
TARGET="/usr/local/sbin/rotina"
HASH_FILE_URL="$RAW_URL/rotina.sha256"

echo "==> Security-Chain installer"
echo ""

# ─────────────────────────────────────────────
# 1. Checar dependências mínimas
# ─────────────────────────────────────────────
for cmd in curl sha256sum install; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Comando necessário não encontrado: $cmd"
    exit 1
  fi
done

# ─────────────────────────────────────────────
# 2. Baixar script
# ─────────────────────────────────────────────
echo "➡️ Baixando $SCRIPT_NAME..."
curl -fsSL "$RAW_URL/$SCRIPT_NAME" -o "$TMP_FILE"

# ─────────────────────────────────────────────
# 3. Baixar hash oficial
# ─────────────────────────────────────────────
echo "➡️ Baixando hash oficial..."
if curl -fsSL "$HASH_FILE_URL" -o /tmp/rotina.sha256; then
  EXPECTED_HASH=$(awk '{print $1}' /tmp/rotina.sha256)
else
  echo "⚠️ Não foi possível baixar o hash oficial"
  echo "⚠️ Continuar sem verificação NÃO é recomendado"
  exit 1
fi

# ─────────────────────────────────────────────
# 4. Verificar integridade
# ─────────────────────────────────────────────
echo "➡️ Verificando integridade..."

DOWNLOADED_HASH=$(sha256sum "$TMP_FILE" | awk '{print $1}')

if [[ "$DOWNLOADED_HASH" != "$EXPECTED_HASH" ]]; then
  echo "❌ ERRO: Hash não confere!"
  echo ""
  echo "Esperado:   $EXPECTED_HASH"
  echo "Encontrado: $DOWNLOADED_HASH"
  echo ""
  echo "⚠️ Possível corrupção ou ataque MITM"
  exit 1
fi

echo "✔ Hash verificado"

# ─────────────────────────────────────────────
# 5. Instalar
# ─────────────────────────────────────────────
echo "➡️ Instalando em $TARGET..."

sudo install -o root -g root -m 750 "$TMP_FILE" "$TARGET"

# ─────────────────────────────────────────────
# 6. Registrar hash local
# ─────────────────────────────────────────────
echo "➡️ Registrando hash local..."
echo "$EXPECTED_HASH  $TARGET" | sudo tee /etc/rotina.sha256 >/dev/null

# ─────────────────────────────────────────────
# 7. Criar logs
# ─────────────────────────────────────────────
echo "➡️ Preparando logs..."
sudo mkdir -p /var/log/rotina
sudo chmod 750 /var/log/rotina

# ─────────────────────────────────────────────
# 8. Final
# ─────────────────────────────────────────────
echo ""
echo "✅ Instalação concluída!"
echo ""
echo "Use:"
echo "  sudo rotina diaria"
echo ""
echo "Opcional:"
echo "  sudo rotina --install   # para configurar timer systemd"
