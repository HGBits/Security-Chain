#!/usr/bin/env bash

# ══════════════════════════════════════════════════════════
#  rotina.sh — Manutenção e segurança do sistema
#
#  Uso: sudo rotina.sh [diaria|semanal|mensal|demanda] [opções]
#       sudo rotina.sh --install
#       sudo rotina.sh --update-hash
# ══════════════════════════════════════════════════════════

set -uo pipefail

# ── Cores ANSI (substitui o `print -P %F{...}%f` do zsh) ───
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_MAGENTA=$'\033[35m'
C_GREY=$'\033[38;5;240m'
C_RESET=$'\033[0m'

# ── Parsing ───────────────────────────────────────────────
MODO=""
DRY_RUN=false
UPDATE_HASH=false
DO_INSTALL=false
AUTO_DEPS=false

for arg in "$@"; do
  case $arg in
    diaria|semanal|mensal|demanda) MODO=$arg ;;
    --dry-run)     DRY_RUN=true ;;
    --update-hash) UPDATE_HASH=true ;;
    --install)     DO_INSTALL=true ;;
    --auto-deps)   AUTO_DEPS=true ;;
  esac
done

MODO=${MODO:-help}

# ── Configuração ──────────────────────────────────────────
LOG_DIR="/var/log/rotina"
HASH_FILE="/etc/rotina.sha256"
SCRIPT_PATH=$(realpath "$0")
SUID_ANTERIOR="$LOG_DIR/suid-anterior.txt"
BIN_BASELINE="$LOG_DIR/bin-baseline.sha256"
TIMEOUT_LENTO=300
TIMEOUT_MEDIO=120

declare -i PASS=0 FAIL=0 WARN=0 SKIP=0

# ══════════════════════════════════════════════════════════
#  DETECÇÃO DE FORMATOS DE PACOTE
#  Tudo que depende de formato usa estas variáveis.
#  Nenhuma função assume um gerenciador específico.
# ══════════════════════════════════════════════════════════
detect_formats() {
  HAS_PACMAN=false; command -v pacman  &>/dev/null && HAS_PACMAN=true
  HAS_PARU=false;   command -v paru    &>/dev/null && HAS_PARU=true
  HAS_YAY=false;    command -v yay     &>/dev/null && HAS_YAY=true
  HAS_FLATPAK=false; command -v flatpak &>/dev/null && HAS_FLATPAK=true
  HAS_SNAP=false;   command -v snap    &>/dev/null && HAS_SNAP=true

  # AUR helper: paru > yay > nenhum
  AUR_HELPER=""
  $HAS_PARU && AUR_HELPER=paru
  [[ -z "$AUR_HELPER" ]] && $HAS_YAY && AUR_HELPER=yay

  # Comandos de gerenciamento (populados dinamicamente)
  PKG_UPDATE=""; PKG_CLEAN=""; PKG_ORPHANS=""; PKG_REMOVE=""; PKG_INSTALL=""
  if [[ -n "$AUR_HELPER" ]]; then
    PKG_UPDATE="$AUR_HELPER -Syu --noconfirm"
    PKG_CLEAN="$AUR_HELPER -Sc --noconfirm"
    PKG_ORPHANS="$AUR_HELPER -Qtdq"
    PKG_REMOVE="$AUR_HELPER -Rns --noconfirm"
    PKG_INSTALL="$AUR_HELPER -S --needed --noconfirm"
  elif $HAS_PACMAN; then
    PKG_UPDATE="pacman -Syu --noconfirm"
    PKG_CLEAN="pacman -Sc --noconfirm"
    PKG_ORPHANS="pacman -Qtdq"
    PKG_REMOVE="pacman -Rns --noconfirm"
    PKG_INSTALL="pacman -S --needed --noconfirm"
  fi
}

detect_formats

# ── Logging ───────────────────────────────────────────────
if [[ "$MODO" != "help" && "$UPDATE_HASH" == false && "$DO_INSTALL" == false ]]; then
  mkdir -p "$LOG_DIR"
  LOGFILE="$LOG_DIR/$(date +%F)-${MODO}.log"
  exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1
  printf '%b\n' "${C_GREY}► Log: $LOGFILE${C_RESET}"
fi

# ── Helpers ───────────────────────────────────────────────
# ok/warn/err auto-incrementam os contadores para garantir
# consistência — não é necessário incrementar manualmente.

header() {
  printf '%b\n' "\n${C_CYAN}═══════════════════════════════${C_RESET}"
  printf '%b\n' "${C_GREEN}  $1${C_RESET}"
  printf '%b\n' "${C_GREY}  $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
  printf '%b\n' "${C_CYAN}═══════════════════════════════${C_RESET}\n"
}

section() { printf '%b\n' "\n${C_YELLOW}► $1 ${C_GREY}[$(date +%H:%M:%S)]${C_RESET}"; }
ok()      { printf '%b\n' "${C_GREEN}  ✔ $1${C_RESET}";  ((PASS++)); }
warn()    { printf '%b\n' "${C_YELLOW}  ⚠ $1${C_RESET}"; ((WARN++)); }
err()     { printf '%b\n' "${C_RED}  ✖ $1${C_RESET}";    ((FAIL++)); }
info()    { printf '%b\n' "${C_BLUE}  ● $1${C_RESET}"; }  # informativo, sem contador

# Comando destrutivo — pulado em dry-run
destrut() {
  local label=$1; shift
  if $DRY_RUN; then
    printf '%b\n' "${C_MAGENTA}  [DRY-RUN]${C_RESET} $*"; ((SKIP++)); return 0
  fi
  "$@"
  local rc=$?
  [[ $rc -eq 0 ]] && ok "$label" || err "$label falhou (rc=$rc)"
  return $rc
}

# Verificação read-only — sempre executa
check() {
  local label=$1; shift
  "$@"
  local rc=$?
  [[ $rc -eq 0 ]] && ok "$label" || err "$label falhou (rc=$rc)"
  return $rc
}

# ══════════════════════════════════════════════════════════
#  INTEGRIDADE DO SCRIPT
# ══════════════════════════════════════════════════════════
cmd_update_hash() {
  sha256sum "$SCRIPT_PATH" > "$HASH_FILE"
  printf '%b\n' "${C_GREEN}Hash atualizado:${C_RESET} $(cat "$HASH_FILE")"
  exit 0
}

check_integrity() {
  if [[ ! -f "$HASH_FILE" ]]; then
    sha256sum "$SCRIPT_PATH" > "$HASH_FILE"
    ok "Hash criado em $HASH_FILE"
    return
  fi
  if sha256sum --check "$HASH_FILE" --status 2>/dev/null; then
    ok "Integridade do script verificada"
  else
    err "INTEGRIDADE COMPROMETIDA — hash não confere!"
    err "Se editou o script legitimamente: sudo $SCRIPT_PATH --update-hash"
    exit 1
  fi
}

# ══════════════════════════════════════════════════════════
#  DEPENDÊNCIAS COM AUTO-INSTALAÇÃO
#  Deps base por modo + deps condicionais por formato detectado.
#  --auto-deps instala sem perguntar; caso contrário, pergunta.
# ══════════════════════════════════════════════════════════

# Mapeamento comando → pacote (para instalação automática)
declare -A CMD_PKG_MAP=(
  [ausearch]=audit
  [aa-status]=apparmor
  [usbguard]=usbguard
  [aide]=aide
  [sbctl]=sbctl
  [paccache]=pacman-contrib
  [snapper]=snapper
  [zramctl]=util-linux
  [getcap]=libcap
  [mokutil]=mokutil
  [pesign]=pesign
  [lnav]=lnav
  [btop]=btop
  [bandwhich]=bandwhich
  [btrfs]=btrfs-progs
)

# Deps base por modo (formato-agnóstico)
declare -A BASE_DEPS
BASE_DEPS[diaria]="systemctl snapper zramctl ausearch journalctl last ss"
BASE_DEPS[semanal]="paccache aide aa-status pacman ausearch usbguard stat awk systemctl"
BASE_DEPS[mensal]="btrfs sbctl cryptsetup auditctl getcap find aide mokutil"
BASE_DEPS[demanda]="ss lsmod journalctl aa-status mokutil"

build_deps_list() {
  local deps="${BASE_DEPS[$MODO]:-}"

  # AUR helper só se disponível
  [[ -n "$AUR_HELPER" ]] && deps+=" $AUR_HELPER"

  # Deps condicionais por formato detectado
  case $MODO in
    semanal|mensal)
      $HAS_FLATPAK && deps+=" flatpak"
      $HAS_SNAP    && deps+=" snap"
      ;;
  esac

  echo "$deps"
}

install_deps() {
  local deps_str
  deps_str=$(build_deps_list)
  local missing_cmds=() missing_pkgs=()

  for cmd in $deps_str; do
    command -v "$cmd" &>/dev/null && continue
    missing_cmds+=("$cmd")
    missing_pkgs+=("${CMD_PKG_MAP[$cmd]:-$cmd}")
  done

  [[ ${#missing_cmds[@]} -eq 0 ]] && { ok "Dependências OK"; return 0; }

  warn "Dependências ausentes: ${missing_cmds[*]}"
  [[ -z "$PKG_INSTALL" ]] && { err "Nenhum gerenciador disponível para instalar"; exit 1; }

  local do_install=false
  if $AUTO_DEPS; then
    do_install=true
  else
    printf '%b\n' "${C_YELLOW}  Instalar agora? [S/n]${C_RESET}"
    read -r resp
    [[ "${resp:-S}" =~ ^[sS]$ ]] && do_install=true
  fi

  if $do_install; then
    if $DRY_RUN; then
      printf '%b\n' "${C_MAGENTA}  [DRY-RUN]${C_RESET} $PKG_INSTALL ${missing_pkgs[*]}"
      ((SKIP++))
    else
      $PKG_INSTALL "${missing_pkgs[@]}" \
        && ok "Dependências instaladas" \
        || { err "Falha ao instalar dependências"; exit 1; }
    fi
  else
    err "Abortando — dependências necessárias não instaladas"
    exit 1
  fi
}

# ══════════════════════════════════════════════════════════
#  INSTALAÇÃO FACILITADA
# ══════════════════════════════════════════════════════════
cmd_install() {
  local target="/usr/local/sbin/rotina"
  local svc_file="/etc/systemd/system/rotina-diaria.service"
  local tmr_file="/etc/systemd/system/rotina-diaria.timer"

  printf '%b\n' "${C_CYAN}Instalando rotina.sh...${C_RESET}\n"

  # Copia e permissões
  install -o root -g root -m 750 "$SCRIPT_PATH" "$target"
  printf '%b\n' "${C_GREEN}  ✔${C_RESET} Script copiado para $target"

  # Registra hash para o novo caminho
  sha256sum "$target" > "$HASH_FILE"
  printf '%b\n' "${C_GREEN}  ✔${C_RESET} Hash registrado em $HASH_FILE"

  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  printf '%b\n' "${C_GREEN}  ✔${C_RESET} Diretório de logs: $LOG_DIR"

  # Timer systemd opcional
  printf '%b\n' "\n${C_YELLOW}Criar timer systemd para rotina diária? [s/N]${C_RESET}"
  read -r resp
  if [[ "$resp" =~ ^[sS]$ ]]; then
    cat > "$svc_file" <<EOF
[Unit]
Description=Rotina diária de manutenção e segurança
After=network.target

[Service]
Type=oneshot
ExecStart=$target diaria
StandardOutput=journal
StandardError=journal
EOF

    cat > "$tmr_file" <<EOF
[Unit]
Description=Timer — rotina diária

[Timer]
OnCalendar=daily
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now rotina-diaria.timer \
      && printf '%b\n' "${C_GREEN}  ✔${C_RESET} Timer habilitado (rotina-diaria.timer)" \
      || printf '%b\n' "${C_RED}  ✖${C_RESET} Falha ao habilitar timer"
  fi

  printf '%b\n' "\n${C_GREEN}Instalação concluída.${C_RESET}"
  printf '%b\n' "  Uso: ${C_CYAN}sudo rotina [diaria|semanal|mensal|demanda]${C_RESET}"
  printf '%b\n' "  Após editar: ${C_CYAN}sudo rotina --update-hash${C_RESET}\n"
  exit 0
}

# ── Detecção LUKS ─────────────────────────────────────────
detect_luks() {
  lsblk -rno NAME,TYPE | awk '$2=="part"{print $1}' | while read -r dev; do
    cryptsetup isLuks "/dev/$dev" 2>/dev/null && echo "/dev/$dev" && return
  done
}

# ══════════════════════════════════════════════════════════
#  VERIFICAÇÃO DE BINÁRIOS CRÍTICOS
#  Duas camadas: pacman -Qkk (checksum + metadados do banco)
#  + baseline SHA256 próprio (detecta mudanças entre updates).
# ══════════════════════════════════════════════════════════
check_binaries() {
  section "Verificação de binários críticos"

  local critical=(
    /usr/bin/sudo
    /usr/bin/su
    /usr/bin/passwd
    /usr/bin/newgrp
    /usr/bin/ssh
    /usr/bin/login
    /usr/lib/polkit-1/polkitd
    /usr/lib/polkit-1/polkit-agent-helper-1
  )

  # ── Camada 1: pacman -Qkk ─────────────────────────────
  # -Qkk verifica SHA256 + metadados de todos os arquivos do pacote
  info "Checando integridade via pacman -Qkk..."
  local seen_pkgs=()
  for bin in "${critical[@]}"; do
    [[ -f "$bin" ]] || continue

    local pkg
    pkg=$(pacman -Qo "$bin" 2>/dev/null | awk '{print $(NF-1)}')
    if [[ -z "$pkg" ]]; then
      warn "$bin sem pacote dono (não gerenciado pelo pacman)"
      continue
    fi

    # Evita verificar o mesmo pacote duas vezes
    if [[ " ${seen_pkgs[*]} " == *" $pkg "* ]]; then continue; fi
    seen_pkgs+=("$pkg")

    local issues
    issues=$(pacman -Qkk "$pkg" 2>&1 | grep -v "^$pkg: 0 altered files")
    if [[ -z "$issues" ]]; then
      ok "$bin ← $pkg (pacman OK)"
    else
      err "$bin ← $pkg — discrepância detectada:"
      echo "$issues" | sed 's/^/    /'
    fi
  done

  # ── Camada 2: baseline SHA256 próprio ─────────────────
  # Detecta substituições mesmo que o pacman não saiba
  info "Checando contra baseline SHA256..."
  local existing_bins=()
  for bin in "${critical[@]}"; do
    [[ -f "$bin" ]] && existing_bins+=("$bin")
  done

  if [[ ! -f "$BIN_BASELINE" ]]; then
    warn "Sem baseline — criando agora (referência para próxima execução)"
    sha256sum "${existing_bins[@]}" 2>/dev/null > "$BIN_BASELINE"
    info "Baseline salvo em $BIN_BASELINE"
  else
    local failed_bins
    failed_bins=$(sha256sum --check "$BIN_BASELINE" 2>/dev/null | grep ": FAILED")
    if [[ -z "$failed_bins" ]]; then
      ok "Hashes batem com baseline ($BIN_BASELINE)"
    else
      err "Binários alterados desde o último baseline:"
      echo "$failed_bins" | sed 's/^/    /'
      warn "Se foi uma atualização legítima: remova $BIN_BASELINE para recriar"
    fi
  fi
}

# ══════════════════════════════════════════════════════════
#  SECURE BOOT + SHIM
#  Extraído como função para ser chamado em mensal e demanda.
#  Detecta automaticamente se shim está em uso ou não.
# ══════════════════════════════════════════════════════════
check_secureboot() {
  section "Secure Boot"

  if ! command -v sbctl &>/dev/null; then
    warn "sbctl não disponível — Secure Boot não verificado"
    return
  fi

  check "sbctl status" sbctl status

  local unsigned
  unsigned=$(sbctl verify 2>&1 | grep "not signed")
  if [[ -z "$unsigned" ]]; then
    ok "Todos os binários EFI assinados"
  else
    warn "Binários EFI não assinados:"
    echo "$unsigned" | sed 's/^/    /'
  fi

  # ── Shim ──────────────────────────────────────────────
  local esp
  esp=$(bootctl -p 2>/dev/null || echo "/boot")
  local shim_files
  shim_files=$(find "$esp" -iname "shim*.efi" 2>/dev/null)

  if [[ -n "$shim_files" ]]; then
    info "Shim detectado:"
    echo "$shim_files" | sed 's/^/    /'

    if command -v mokutil &>/dev/null; then
      printf '%b\n' "\n${C_BLUE}  MOK — chaves matriculadas:${C_RESET}"
      mokutil --list-enrolled 2>/dev/null \
        || warn "Nenhuma chave MOK matriculada"

      printf '%b\n' "\n${C_BLUE}  MOK — pendências de enroll:${C_RESET}"
      local mok_new
      mok_new=$(mokutil --list-new 2>/dev/null)
      if [[ -n "$mok_new" ]]; then
        warn "MOK com enroll pendente no próximo boot!"
        echo "$mok_new" | sed 's/^/    /'
      else
        ok "Sem pendências MOK"
      fi

      printf '%b\n' "\n${C_BLUE}  MOK — estado de deleção pendente:${C_RESET}"
      local mok_del
      mok_del=$(mokutil --list-delete 2>/dev/null)
      [[ -n "$mok_del" ]] \
        && { warn "Deleção MOK pendente:"; echo "$mok_del" | sed 's/^/    /'; } \
        || ok "Sem deleções MOK pendentes"
    fi

    # Assinatura do shim (requer pesign)
    if command -v pesign &>/dev/null; then
      printf '%b\n' "\n${C_BLUE}  Assinatura do shim:${C_RESET}"
      while IFS= read -r shim; do
        info "$shim"
        pesign --show-signature --in="$shim" 2>/dev/null \
          | grep -iE "subject|issuer|not (before|after)" \
          | sed 's/^/    /'
      done <<< "$shim_files"
    else
      warn "pesign não disponível — assinatura do shim não verificada"
    fi

  else
    ok "Shim não utilizado — cadeia de boot direta (sbctl)"
  fi

  # TPM2
  printf '%b\n' "\n${C_BLUE}  TPM2 — chave pública:${C_RESET}"
  systemd-cryptenroll --tpm2-device=auto --print-pubkey=tpm2 2>/dev/null \
    || warn "TPM2 não configurado (ou systemd-cryptenroll indisponível)"
}

# ══════════════════════════════════════════════════════════
#  ROTINAS
# ══════════════════════════════════════════════════════════

rotina_diaria() {
  header "ROTINA DIÁRIA"
  section "Sistema"

  # ── Atualização por formato detectado ─────────────────
  if [[ -n "$PKG_UPDATE" ]]; then
    printf '%b\n' "\n${C_BLUE}Atualização (${AUR_HELPER:-pacman}):${C_RESET}"
    destrut "Atualização pacman/AUR" $PKG_UPDATE
  fi

  if $HAS_FLATPAK; then
    printf '%b\n' "\n${C_BLUE}Flatpak — atualização:${C_RESET}"
    destrut "Flatpak update" flatpak update -y
  fi

  if $HAS_SNAP; then
    printf '%b\n' "\n${C_BLUE}Snap — atualização:${C_RESET}"
    destrut "Snap refresh" snap refresh
  fi

  printf '%b\n' "\n${C_BLUE}Serviços com falha:${C_RESET}"
  local failed
  failed=$(systemctl --failed --no-legend 2>/dev/null)
  if [[ -z "$failed" ]]; then
    ok "Nenhum serviço com falha"
  else
    warn "Serviços com falha:"
    echo "$failed"
  fi

  printf '%b\n' "\n${C_BLUE}Últimos snapshots (snapper):${C_RESET}"
  if command -v snapper &>/dev/null; then
    snapper -c root list | tail -3
  else
    warn "snapper não disponível"
  fi

  printf '%b\n' "\n${C_BLUE}ZRAM:${C_RESET}"
  zramctl

  section "Segurança"

  printf '%b\n' "\n${C_BLUE}Falhas de autenticação hoje:${C_RESET}"
  local auth_fail
  auth_fail=$(ausearch -m USER_AUTH,USER_LOGIN -sv no -ts today 2>/dev/null)
  if [[ -z "$auth_fail" ]]; then
    ok "Sem falhas de autenticação"
  else
    warn "Falhas detectadas:"
    echo "$auth_fail"
  fi

  printf '%b\n' "\n${C_BLUE}AppArmor DENIED hoje:${C_RESET}"
  local aa_denied
  aa_denied=$(journalctl -b --since today 2>/dev/null | grep 'apparmor="DENIED"')
  if [[ -z "$aa_denied" ]]; then
    ok "Nenhum DENIED"
  else
    warn "AppArmor DENIED:"
    echo "$aa_denied"
  fi

  printf '%b\n' "\n${C_BLUE}Últimos logins:${C_RESET}"
  last -n 20

  printf '%b\n' "\n${C_BLUE}Tentativas falhas de login:${C_RESET}"
  lastb -n 20 2>/dev/null || warn "lastb indisponível"

  printf '%b\n' "\n${C_BLUE}Portas abertas:${C_RESET}"
  ss -tulnp

  printf '%b\n' "\n${C_BLUE}USBGuard hoje:${C_RESET}"
  if command -v usbguard &>/dev/null; then
    local usb_events
    usb_events=$(journalctl -u usbguard --since today 2>/dev/null \
      | grep -i "block\|reject\|DENY")
    if [[ -z "$usb_events" ]]; then
      ok "Sem eventos USBGuard"
    else
      warn "Eventos USBGuard:"
      echo "$usb_events"
    fi
  else
    warn "USBGuard não instalado"
  fi
}

# ─────────────────────────────────────────────────────────

rotina_semanal() {
  header "ROTINA SEMANAL"
  section "Sistema"

  printf '%b\n' "\n${C_BLUE}Snapshot pré-manutenção:${C_RESET}"
  if command -v snapper &>/dev/null; then
    destrut "Snapshot" snapper -c root create \
      --description "pre-manutencao-$(date +%F)"
  else
    warn "snapper não disponível — snapshot pulado"
  fi

  # ── Limpeza por formato ────────────────────────────────
  if [[ -n "$PKG_CLEAN" ]]; then
    printf '%b\n' "\n${C_BLUE}Limpeza cache (${AUR_HELPER:-pacman}):${C_RESET}"
    destrut "Cache ${AUR_HELPER:-pacman}" $PKG_CLEAN
  fi

  if command -v paccache &>/dev/null; then
    printf '%b\n' "\n${C_BLUE}Cache de pacotes (manter 2):${C_RESET}"
    destrut "paccache" paccache -rk2
  fi

  if $HAS_FLATPAK; then
    printf '%b\n' "\n${C_BLUE}Flatpak — remover não utilizados:${C_RESET}"
    destrut "Flatpak cleanup" flatpak uninstall --unused -y

    printf '%b\n' "\n${C_BLUE}Flatpak — overrides de permissão:${C_RESET}"
    flatpak override --show 2>/dev/null || ok "Sem overrides"
  fi

  if $HAS_SNAP; then
    printf '%b\n' "\n${C_BLUE}Snap — remover revisões antigas (disabled):${C_RESET}"
    if $DRY_RUN; then
      printf '%b\n' "${C_MAGENTA}  [DRY-RUN]${C_RESET} snap remove <name> --revision=<rev>  (todas disabled)"
      ((SKIP++))
    else
      snap list --all 2>/dev/null \
        | awk 'NR>1 && /disabled/ {print $1, $3}' \
        | while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" \
              && printf '%b\n' "${C_GREEN}  ✔${C_RESET} Removida revisão $revision de $snapname" \
              || printf '%b\n' "${C_RED}  ✖${C_RESET} Falha ao remover $snapname rev $revision"
          done
      ok "Revisões antigas de snaps removidas"
    fi

    printf '%b\n' "\n${C_BLUE}Snap — confinamento:${C_RESET}"
    local classic_snaps
    classic_snaps=$(snap list 2>/dev/null \
      | awk 'NR>1' \
      | while read -r name _rest; do
          local conf
          conf=$(snap info "$name" 2>/dev/null | awk '/^confinement:/{print $2}')
          [[ "$conf" != "strict" ]] && echo "$name ($conf)"
        done)
    if [[ -z "$classic_snaps" ]]; then
      ok "Todos os snaps com confinamento strict"
    else
      warn "Snaps sem confinamento strict:"
      echo "$classic_snaps" | sed 's/^/    /'
    fi
  fi

  printf '%b\n' "\n${C_BLUE}Órfãos:${C_RESET}"
  if [[ -n "$PKG_ORPHANS" ]]; then
    local orfaos
    orfaos=$(eval "$PKG_ORPHANS" 2>/dev/null)
    if [[ -n "$orfaos" ]]; then
      echo "$orfaos"
      if $DRY_RUN; then
        printf '%b\n' "${C_MAGENTA}  [DRY-RUN]${C_RESET} $PKG_REMOVE <orphans>"
        ((SKIP++))
      else
        echo "$orfaos" | xargs $PKG_REMOVE
        local rc=$?
        [[ $rc -eq 0 ]] && ok "Órfãos removidos" || err "Remoção falhou (rc=$rc)"
      fi
    else
      ok "Sem órfãos"
    fi
  fi

  section "Segurança"

  check_binaries

  printf '%b\n' "\n${C_BLUE}AIDE — verificação de integridade:${C_RESET}"
  if command -v aide &>/dev/null; then
    aide --check 2>&1 | tee "$LOG_DIR/aide-$(date +%F).log"
    local aide_rc=${PIPESTATUS[0]}
    [[ $aide_rc -eq 0 ]] && ok "AIDE OK" || warn "AIDE reportou mudanças (rc=$aide_rc)"
  else
    warn "AIDE não instalado"
  fi

  printf '%b\n' "\n${C_BLUE}AppArmor — perfis em complain:${C_RESET}"
  local complain
  complain=$(aa-status 2>/dev/null | grep complain)
  if [[ -z "$complain" ]]; then
    ok "Nenhum perfil em complain"
  else
    warn "Perfis em complain:"
    echo "$complain"
  fi

  printf '%b\n' "\n${C_BLUE}Arquivos com erros (pacman -Qk):${C_RESET}"
  local qk_erros
  qk_erros=$(pacman -Qk 2>&1 | grep -v "0 missing files")
  if [[ -z "$qk_erros" ]]; then
    ok "Todos os arquivos íntegros"
  else
    warn "Erros encontrados:"
    echo "$qk_erros"
  fi

  printf '%b\n' "\n${C_BLUE}Audit — acessos na semana:${C_RESET}"
  ausearch -k access -ts week 2>/dev/null || ok "Sem eventos registrados"

  if command -v usbguard &>/dev/null; then
    check "USBGuard rules" usbguard list-rules
  fi

  check "stat críticos" stat /etc/passwd /etc/shadow /etc/sudoers

  printf '%b\n' "\n${C_BLUE}Regras Polkit:${C_RESET}"
  ls -la /etc/polkit-1/rules.d/

  printf '%b\n' "\n${C_BLUE}Usuários (UID >= 1000):${C_RESET}"
  awk -F: '$3 >= 1000 {print $1, $3}' /etc/passwd

  printf '%b\n' "\n${C_BLUE}Usuários com UID 0:${C_RESET}"
  local uid0
  uid0=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
  echo "$uid0"
  [[ $(echo "$uid0" | wc -l) -gt 1 ]] \
    && warn "Mais de um UID 0 detectado!" \
    || ok "UID 0 OK (apenas root)"

  printf '%b\n' "\n${C_BLUE}Cron jobs:${C_RESET}"
  ls -la /etc/cron* /var/spool/cron/ 2>/dev/null || ok "Sem cron jobs"

  printf '%b\n' "\n${C_BLUE}Timers systemd:${C_RESET}"
  systemctl list-timers --all
}

# ─────────────────────────────────────────────────────────

rotina_mensal() {
  header "ROTINA MENSAL"

  local LUKS_DEV
  LUKS_DEV=$(detect_luks)

  section "Sistema"

  printf '%b\n' "\n${C_BLUE}Uso do Btrfs:${C_RESET}"
  check "Btrfs usage" btrfs filesystem usage /

  printf '%b\n' "\n${C_BLUE}Subvolumes:${C_RESET}"
  btrfs subvolume list /

  printf '%b\n' "\n${C_BLUE}Balance Btrfs (data > 85%%):${C_RESET}"
  destrut "Btrfs balance" timeout "$TIMEOUT_LENTO" btrfs balance start -dusage=85 /

  check_secureboot

  section "Segurança"

  if [[ -n "$LUKS_DEV" ]]; then
    check "LUKS dump" cryptsetup luksDump "$LUKS_DEV"

    local backup="$LOG_DIR/luks-header-$(date +%F).bin"
    destrut "LUKS backup" cryptsetup luksHeaderBackup "$LUKS_DEV" \
      --header-backup-file "$backup"
    [[ -f "$backup" ]] && ok "LUKS header salvo em $backup"
  else
    warn "Dispositivo LUKS não detectado automaticamente"
  fi

  check "auditctl" auditctl -l

  printf '%b\n' "\n${C_BLUE}Capabilities atribuídas:${C_RESET}"
  getcap -r / 2>/dev/null | grep -v "^/proc" || ok "Nenhuma capability extra"

  printf '%b\n' "\n${C_BLUE}SUID/SGID — comparando com baseline:${C_RESET}"
  local suid_atual="/tmp/suid-$(date +%F).txt"
  timeout "$TIMEOUT_MEDIO" find / -perm /6000 -type f 2>/dev/null | sort > "$suid_atual"
  if [[ -f "$SUID_ANTERIOR" ]]; then
    local diff_out
    diff_out=$(diff "$SUID_ANTERIOR" "$suid_atual")
    if [[ -z "$diff_out" ]]; then
      ok "Sem mudanças em SUID/SGID"
    else
      warn "Mudanças detectadas:"
      echo "$diff_out"
    fi
  else
    warn "Sem baseline anterior — criado agora para próximo mês"
  fi
  cp "$suid_atual" "$SUID_ANTERIOR"

  # Renovar baseline de binários críticos (após mês limpo)
  printf '%b\n' "\n${C_BLUE}Atualizar baseline de binários críticos? [s/N]${C_RESET}"
  read -r resp
  if [[ "$resp" =~ ^[sS]$ ]]; then
    local critical=(
      /usr/bin/sudo /usr/bin/su /usr/bin/passwd /usr/bin/newgrp
      /usr/bin/ssh /usr/bin/login
      /usr/lib/polkit-1/polkitd
      /usr/lib/polkit-1/polkit-agent-helper-1
    )
    local existing=()
    for b in "${critical[@]}"; do [[ -f "$b" ]] && existing+=("$b"); done
    sha256sum "${existing[@]}" 2>/dev/null > "$BIN_BASELINE"
    ok "Baseline atualizado: $BIN_BASELINE"
  fi

  printf '%b\n' "\n${C_BLUE}AIDE — atualizando base:${C_RESET}"
  if command -v aide &>/dev/null; then
    destrut "AIDE update" sh -c \
      'aide --update && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db'
  else
    warn "AIDE não instalado"
  fi
}

# ─────────────────────────────────────────────────────────

rotina_demanda() {
  header "SOB DEMANDA / INVESTIGAÇÃO"
  section "Sistema"

  printf '%b\n' "\n${C_BLUE}Conexões ativas:${C_RESET}"
  ss -tupan

  printf '%b\n' "\n${C_BLUE}Módulos do kernel:${C_RESET}"
  lsmod | sort

  printf '%b\n' "\n${C_BLUE}Forgejo — logs de hoje:${C_RESET}"
  journalctl -u forgejo --since today 2>/dev/null \
    || warn "Forgejo não encontrado como serviço systemd"

  # Status de cada formato de pacote detectado
  section "Inventário de formatos"

  if [[ -n "$AUR_HELPER" ]]; then
    info "AUR helper: $AUR_HELPER"
    $AUR_HELPER -Qu 2>/dev/null | head -20 \
      && info "Pacotes com atualização disponível (acima)" \
      || ok "Sem atualizações pendentes"
  fi

  if $HAS_FLATPAK; then
    printf '%b\n' "\n${C_BLUE}Flatpak — instalados:${C_RESET}"
    flatpak list --columns=application,version,installation
  fi

  if $HAS_SNAP; then
    printf '%b\n' "\n${C_BLUE}Snap — instalados:${C_RESET}"
    snap list
  fi

  section "Segurança"

  aa-status --pretty-json 2>/dev/null || aa-status

  pkaction --verbose 2>/dev/null | grep -A5 "implicitany.*yes"

  check_secureboot

  printf '%b\n' ""
  warn "Para análise de PID:     ausearch -p <PID>"
  warn "Para logs de auditoria:  lnav /var/log/audit/audit.log"
  warn "Para monitoramento:      btop"
}

# ══════════════════════════════════════════════════════════
#  RESUMO
# ══════════════════════════════════════════════════════════
resumo() {
  printf '%b\n' "\n${C_CYAN}═══════════════════════════════${C_RESET}"
  printf '%b\n' "${C_GREEN}  RESUMO${C_RESET}"
  printf '%b\n' "${C_CYAN}═══════════════════════════════${C_RESET}"
  printf '%b\n' "  ${C_GREEN}✔ Passou:   $PASS${C_RESET}"
  [[ $FAIL -gt 0 ]] \
    && printf '%b\n' "  ${C_RED}✖ Falhou:   $FAIL${C_RESET}" \
    || printf '%b\n' "  ${C_GREEN}✖ Falhou:   $FAIL${C_RESET}"
  [[ $WARN -gt 0 ]] \
    && printf '%b\n' "  ${C_YELLOW}⚠ Avisos:   $WARN${C_RESET}" \
    || printf '%b\n' "  ${C_GREEN}⚠ Avisos:   $WARN${C_RESET}"
  $DRY_RUN && printf '%b\n' "  ${C_MAGENTA}⊘ Pulados:  $SKIP${C_RESET}"
  [[ -n "${LOGFILE:-}" ]] && printf '%b\n' "  ${C_GREY}Log:        $LOGFILE${C_RESET}"
  printf '%b\n' "${C_CYAN}═══════════════════════════════${C_RESET}\n"
  [[ $FAIL -eq 0 ]]
}

# ── Ajuda ─────────────────────────────────────────────────
uso() {
  printf '%b\n' "\n${C_CYAN}Uso:${C_RESET} sudo rotina [modo] [opções]\n"
  printf '%b\n' "  ${C_GREEN}Modos:${C_RESET}"
  printf '%b\n' "    diaria   — atualização + verificações rápidas"
  printf '%b\n' "    semanal  — diaria + limpeza + integridade + auditoria"
  printf '%b\n' "    mensal   — semanal + btrfs + LUKS + SUID + AIDE update"
  printf '%b\n' "    demanda  — investigação e ferramentas manuais\n"
  printf '%b\n' "  ${C_GREEN}Opções:${C_RESET}"
  printf '%b\n' "    --dry-run      mostra o que seria feito sem executar destrutivos"
  printf '%b\n' "    --auto-deps    instala dependências ausentes sem perguntar"
  printf '%b\n' "    --update-hash  atualiza hash após editar o script"
  printf '%b\n' "    --install      instala em /usr/local/sbin/rotina + timer opcional\n"
  printf '%b\n' "  ${C_GREEN}Formatos detectados:${C_RESET}"
  $HAS_PARU    && printf '%b\n' "    ${C_GREEN}✔${C_RESET} paru"    || printf '%b\n' "    ${C_GREY}–${C_RESET} paru"
  $HAS_YAY     && printf '%b\n' "    ${C_GREEN}✔${C_RESET} yay"     || printf '%b\n' "    ${C_GREY}–${C_RESET} yay"
  $HAS_PACMAN  && printf '%b\n' "    ${C_GREEN}✔${C_RESET} pacman"  || printf '%b\n' "    ${C_GREY}–${C_RESET} pacman"
  $HAS_FLATPAK && printf '%b\n' "    ${C_GREEN}✔${C_RESET} flatpak" || printf '%b\n' "    ${C_GREY}–${C_RESET} flatpak"
  $HAS_SNAP    && printf '%b\n' "    ${C_GREEN}✔${C_RESET} snap"    || printf '%b\n' "    ${C_GREY}–${C_RESET} snap"
  [[ -n "$AUR_HELPER" ]] \
    && printf '%b\n' "    ${C_GREY}AUR helper ativo: $AUR_HELPER${C_RESET}"
  printf '%b\n' ""
}

# ══════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════
[[ "$UPDATE_HASH" == true ]] && cmd_update_hash
[[ "$DO_INSTALL"  == true ]] && cmd_install

if [[ "$MODO" != "help" ]]; then
  check_integrity
  install_deps
  $DRY_RUN && warn "Modo DRY-RUN ativo — destrutivos não serão executados\n"
fi

case $MODO in
  diaria)  rotina_diaria;                                resumo ;;
  semanal) rotina_diaria; rotina_semanal;                resumo ;;
  mensal)  rotina_diaria; rotina_semanal; rotina_mensal; resumo ;;
  demanda) rotina_demanda;                               resumo ;;
  *)       uso ;;
esac
