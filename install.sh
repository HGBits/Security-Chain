#!/usr/bin/env bash
set -euo pipefail

REPO="HGBits/Security-Chain"
BRANCH="main"
RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

SCRIPT_NAME="rotina.zsh"
TMP_FILE="/tmp/$SCRIPT_NAME"
TARGET="/usr/local/sbin/rotina"
HASH_FILE_URL="$RAW_URL/rotina.sha256"

ZSH_AVAILABLE=0
ZSH_INSTALL_ATTEMPTED=0
ZSH_INSTALL_FAILED=0
SHELL_CHANGED=0

echo "==> Security-Chain installer"
echo ""

CURRENT_SHELL="${SHELL:-unknown}"
echo "➡️ Shell atual: $CURRENT_SHELL"

# ─────────────────────────────────────────────
# 1. Dependências
# ─────────────────────────────────────────────
for cmd in curl sha256sum install; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Comando necessário não encontrado: $cmd"
    exit 1
  fi
done

# ─────────────────────────────────────────────
# 2. Verificar / instalar zsh
# ─────────────────────────────────────────────
if command -v zsh >/dev/null 2>&1; then
  ZSH_AVAILABLE=1
else
  echo "➡️ zsh não encontrado, tentando instalar..."
  ZSH_INSTALL_ATTEMPTED=1

  if command -v apt >/dev/null 2>&1; then
    sudo apt update && sudo apt install -y zsh || ZSH_INSTALL_FAILED=1
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y zsh || ZSH_INSTALL_FAILED=1
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y zsh || ZSH_INSTALL_FAILED=1
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm zsh || ZSH_INSTALL_FAILED=1
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add zsh || ZSH_INSTALL_FAILED=1
  else
    echo "⚠️ Gerenciador de pacotes não suportado"
    ZSH_INSTALL_FAILED=1
  fi

  if command -v zsh >/dev/null 2>&1; then
    ZSH_AVAILABLE=1
    echo "✔ zsh instalado com sucesso"
  fi
fi

# ─────────────────────────────────────────────
# 3. Perguntar troca de shell (seguro)
# ─────────────────────────────────────────────
if [[ "$ZSH_AVAILABLE" -eq 1 ]]; then
  ZSH_PATH="$(command -v zsh)"

  if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
    if [[ -t 0 ]]; then
      echo ""
      echo "➡️ O shell padrão atual não é zsh."
      echo "Deseja alterar para zsh? [y/N]"
      read -r ANSWER

      case "$ANSWER" in
        y|Y|yes|YES)
          if chsh -s "$ZSH_PATH"; then
            SHELL_CHANGED=1
            echo "✔ Shell padrão alterado para zsh (válido no próximo login)"
          else
            echo "⚠️ Não foi possível alterar o shell automaticamente"
          fi
          ;;
        *)
          echo "➡️ Mantendo shell atual"
          ;;
      esac
    else
      echo "➡️ Ambiente não interativo — não alterando shell"
    fi
  fi
fi

# ─────────────────────────────────────────────
# 4. Baixar script
# ─────────────────────────────────────────────
echo "➡️ Baixando $SCRIPT_NAME..."
curl -fsSL "$RAW_URL/$SCRIPT_NAME" -o "$TMP_FILE"

# ─────────────────────────────────────────────
# 5. Hash
# ─────────────────────────────────────────────
echo "➡️ Baixando hash oficial..."
if curl -fsSL "$HASH_FILE_URL" -o /tmp/rotina.sha256; then
  EXPECTED_HASH=$(awk '{print $1}' /tmp/rotina.sha256)
else
  echo "⚠️ Não foi possível baixar o hash oficial"
  exit 1
fi

echo "➡️ Verificando integridade..."
DOWNLOADED_HASH=$(sha256sum "$TMP_FILE" | awk '{print $1}')

if [[ "$DOWNLOADED_HASH" != "$EXPECTED_HASH" ]]; then
  echo "❌ ERRO: Hash não confere!"
  exit 1
fi

echo "✔ Hash verificado"

# ─────────────────────────────────────────────
# 6. Instalar
# ─────────────────────────────────────────────
echo "➡️ Instalando em $TARGET..."
sudo install -o root -g root -m 750 "$TMP_FILE" "$TARGET"

# ─────────────────────────────────────────────
# 7. Hash local
# ─────────────────────────────────────────────
echo "➡️ Registrando hash local..."
echo "$EXPECTED_HASH  $TARGET" | sudo tee /etc/rotina.sha256 >/dev/null

# ─────────────────────────────────────────────
# 8. Logs
# ─────────────────────────────────────────────
echo "➡️ Preparando logs..."
sudo mkdir -p /var/log/rotina
sudo chmod 750 /var/log/rotina

# ─────────────────────────────────────────────
# 9. Final
# ─────────────────────────────────────────────
echo ""
echo "✅ Instalação concluída!"
echo ""

echo "Use:"
echo "  sudo rotina diaria"
echo ""

# Avisos finais
if [[ "$ZSH_AVAILABLE" -eq 0 ]]; then
  echo "⚠️ AVISO:"
  echo "O script depende do zsh e não foi possível instalá-lo automaticamente."
elif [[ "$SHELL_CHANGED" -eq 1 ]]; then
  echo "➡️ Abra uma nova sessão para usar o zsh como padrão."
fi
