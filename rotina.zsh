#!/usr/bin/env zsh

# ══════════════════════════════════════════════════════════
#  rotina.zsh — Manutenção e segurança do sistema
#
#  Uso: sudo rotina.zsh [diaria|semanal|mensal|demanda] [opções]
#       sudo rotina.zsh --install
#       sudo rotina.zsh --update-hash
# ══════════════════════════════════════════════════════════

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

typeset -i PASS=0 FAIL=0 WARN=0 SKIP=0

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
  print -P "%F{240}► Log: $LOGFILE%f"
fi

# ── Helpers ───────────────────────────────────────────────
# ok/warn/err auto-incrementam os contadores para garantir
# consistência — não é necessário incrementar manualmente.

header() {
  print -P "\n%F{cyan}═══════════════════════════════%f"
  print -P "%F{green}  $1%f"
  print -P "%F{240}  $(date '+%Y-%m-%d %H:%M:%S')%f"
  print -P "%F{cyan}═══════════════════════════════%f\n"
}

section() { print -P "\n%F{yellow}► $1 %F{240}[$(date +%H:%M:%S)]%f" }
ok()      { print -P "%F{green}  ✔ $1%f";  ((PASS++)) }
warn()    { print -P "%F{yellow}  ⚠ $1%f"; ((WARN++)) }
err()     { print -P "%F{red}  ✖ $1%f";   ((FAIL++)) }
info()    { print -P "%F{blue}  ● $1%f" }  # informativo, sem contador

# Comando destrutivo — pulado em dry-run
destrut() {
  local label=$1; shift
  if $DRY_RUN; then
    print -P "%F{magenta}  [DRY-RUN]%f $*"; ((SKIP++)); return 0
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
  print -P "%F{green}Hash atualizado:%f $(cat $HASH_FILE)"
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
typeset -A CMD_PKG_MAP
CMD_PKG_MAP=(
  ausearch    audit
  aa-status   apparmor
  usbguard    usbguard
  aide        aide
  sbctl       sbctl
  paccache    pacman-contrib
  snapper     snapper
  zramctl     util-linux
  getcap      libcap
  mokutil     mokutil
  pesign      pesign
  lnav        lnav
  btop        btop
  bandwhich   bandwhich
  btrfs       btrfs-progs
)

# Deps base por modo (formato-agnóstico)
typeset -A BASE_DEPS
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

  for cmd in ${=deps_str}; do
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
    print -P "%F{yellow}  Instalar agora? [S/n]%f"
    read -r resp
    [[ "${resp:-S}" =~ ^[sS]$ ]] && do_install=true
  fi

  if $do_install; then
    if $DRY_RUN; then
      print -P "%F{magenta}  [DRY-RUN]%f $PKG_INSTALL ${missing_pkgs[*]}"
      ((SKIP++))
    else
      ${=PKG_INSTALL} "${missing_pkgs[@]}" \
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

  print -P "%F{cyan}Instalando rotina.zsh...%f\n"

  # Copia e permissões
  install -o root -g root -m 750 "$SCRIPT_PATH" "$target"
  print -P "%F{green}  ✔%f Script copiado para $target"

  # Registra hash para o novo caminho
  sha256sum "$target" > "$HASH_FILE"
  print -P "%F{green}  ✔%f Hash registrado em $HASH_FILE"

  mkdir -p "$LOG_DIR"
  chmod 750 "$LOG_DIR"
  print -P "%F{green}  ✔%f Diretório de logs: $LOG_DIR"

  # Timer systemd opcional
  print -P "\n%F{yellow}Criar timer systemd para rotina diária? [s/N]%f"
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
      && print -P "%F{green}  ✔%f Timer habilitado (rotina-diaria.timer)" \
      || print -P "%F{red}  ✖%f Falha ao habilitar timer"
  fi

  print -P "\n%F{green}Instalação concluída.%f"
  print -P "  Uso: %F{cyan}sudo rotina [diaria|semanal|mensal|demanda]%f"
  print -P "  Após editar: %F{cyan}sudo rotina --update-hash%f\n"
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
      print -P "\n%F{blue}  MOK — chaves matriculadas:%f"
      mokutil --list-enrolled 2>/dev/null \
        || warn "Nenhuma chave MOK matriculada"

      print -P "\n%F{blue}  MOK — pendências de enroll:%f"
      local mok_new
      mok_new=$(mokutil --list-new 2>/dev/null)
      if [[ -n "$mok_new" ]]; then
        warn "MOK com enroll pendente no próximo boot!"
        echo "$mok_new" | sed 's/^/    /'
      else
        ok "Sem pendências MOK"
      fi

      print -P "\n%F{blue}  MOK — estado de deleção pendente:%f"
      local mok_del
      mok_del=$(mokutil --list-delete 2>/dev/null)
      [[ -n "$mok_del" ]] \
        && { warn "Deleção MOK pendente:"; echo "$mok_del" | sed 's/^/    /'; } \
        || ok "Sem deleções MOK pendentes"
    fi

    # Assinatura do shim (requer pesign)
    if command -v pesign &>/dev/null; then
      print -P "\n%F{blue}  Assinatura do shim:%f"
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
  print -P "\n%F{blue}  TPM2 — chave pública:%f"
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
    print -P "\n%F{blue}Atualização (${AUR_HELPER:-pacman}):%f"
    destrut "Atualização pacman/AUR" ${=PKG_UPDATE}
  fi

  if $HAS_FLATPAK; then
    print -P "\n%F{blue}Flatpak — atualização:%f"
    destrut "Flatpak update" flatpak update -y
  fi

  if $HAS_SNAP; then
    print -P "\n%F{blue}Snap — atualização:%f"
    destrut "Snap refresh" snap refresh
  fi

  print -P "\n%F{blue}Serviços com falha:%f"
  local failed
  failed=$(systemctl --failed --no-legend 2>/dev/null)
  if [[ -z "$failed" ]]; then
    ok "Nenhum serviço com falha"
  else
    warn "Serviços com falha:"
    echo "$failed"
  fi

  print -P "\n%F{blue}Últimos snapshots (snapper):%f"
  if command -v snapper &>/dev/null; then
    snapper -c root list | tail -3
  else
    warn "snapper não disponível"
  fi

  print -P "\n%F{blue}ZRAM:%f"
  zramctl

  section "Segurança"

  print -P "\n%F{blue}Falhas de autenticação hoje:%f"
  local auth_fail
  auth_fail=$(ausearch -m USER_AUTH,USER_LOGIN -sv no -ts today 2>/dev/null)
  if [[ -z "$auth_fail" ]]; then
    ok "Sem falhas de autenticação"
  else
    warn "Falhas detectadas:"
    echo "$auth_fail"
  fi

  print -P "\n%F{blue}AppArmor DENIED hoje:%f"
  local aa_denied
  aa_denied=$(journalctl -b --since today 2>/dev/null | grep 'apparmor="DENIED"')
  if [[ -z "$aa_denied" ]]; then
    ok "Nenhum DENIED"
  else
    warn "AppArmor DENIED:"
    echo "$aa_denied"
  fi

  print -P "\n%F{blue}Últimos logins:%f"
  last -n 20

  print -P "\n%F{blue}Tentativas falhas de login:%f"
  lastb -n 20 2>/dev/null || warn "lastb indisponível"

  print -P "\n%F{blue}Portas abertas:%f"
  ss -tulnp

  print -P "\n%F{blue}USBGuard hoje:%f"
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

  print -P "\n%F{blue}Snapshot pré-manutenção:%f"
  if command -v snapper &>/dev/null; then
    destrut "Snapshot" snapper -c root create \
      --description "pre-manutencao-$(date +%F)"
  else
    warn "snapper não disponível — snapshot pulado"
  fi

  # ── Limpeza por formato ────────────────────────────────
  if [[ -n "$PKG_CLEAN" ]]; then
    print -P "\n%F{blue}Limpeza cache (${AUR_HELPER:-pacman}):%f"
    destrut "Cache ${AUR_HELPER:-pacman}" ${=PKG_CLEAN}
  fi

  if command -v paccache &>/dev/null; then
    print -P "\n%F{blue}Cache de pacotes (manter 2):%f"
    destrut "paccache" paccache -rk2
  fi

  if $HAS_FLATPAK; then
    print -P "\n%F{blue}Flatpak — remover não utilizados:%f"
    destrut "Flatpak cleanup" flatpak uninstall --unused -y

    print -P "\n%F{blue}Flatpak — overrides de permissão:%f"
    flatpak override --show 2>/dev/null || ok "Sem overrides"
  fi

  if $HAS_SNAP; then
    print -P "\n%F{blue}Snap — remover revisões antigas (disabled):%f"
    if $DRY_RUN; then
      print -P "%F{magenta}  [DRY-RUN]%f snap remove <name> --revision=<rev>  (todas disabled)"
      ((SKIP++))
    else
      snap list --all 2>/dev/null \
        | awk 'NR>1 && /disabled/ {print $1, $3}' \
        | while read -r snapname revision; do
            snap remove "$snapname" --revision="$revision" \
              && print -P "%F{green}  ✔%f Removida revisão $revision de $snapname" \
              || print -P "%F{red}  ✖%f Falha ao remover $snapname rev $revision"
          done
      ok "Revisões antigas de snaps removidas"
    fi

    print -P "\n%F{blue}Snap — confinamento:%f"
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

  print -P "\n%F{blue}Órfãos:%f"
  if [[ -n "$PKG_ORPHANS" ]]; then
    local orfaos
    orfaos=$(eval "$PKG_ORPHANS" 2>/dev/null)
    if [[ -n "$orfaos" ]]; then
      echo "$orfaos"
      if $DRY_RUN; then
        print -P "%F{magenta}  [DRY-RUN]%f ${=PKG_REMOVE} <orphans>"
        ((SKIP++))
      else
        echo "$orfaos" | ${=PKG_REMOVE} -
        local rc=$?
        [[ $rc -eq 0 ]] && ok "Órfãos removidos" || err "Remoção falhou (rc=$rc)"
      fi
    else
      ok "Sem órfãos"
    fi
  fi

  section "Segurança"

  check_binaries

  print -P "\n%F{blue}AIDE — verificação de integridade:%f"
  if command -v aide &>/dev/null; then
    aide --check 2>&1 | tee "$LOG_DIR/aide-$(date +%F).log"
    local aide_rc=${pipestatus[1]}
    [[ $aide_rc -eq 0 ]] && ok "AIDE OK" || warn "AIDE reportou mudanças (rc=$aide_rc)"
  else
    warn "AIDE não instalado"
  fi

  print -P "\n%F{blue}AppArmor — perfis em complain:%f"
  local complain
  complain=$(aa-status 2>/dev/null | grep complain)
  if [[ -z "$complain" ]]; then
    ok "Nenhum perfil em complain"
  else
    warn "Perfis em complain:"
    echo "$complain"
  fi

  print -P "\n%F{blue}Arquivos com erros (pacman -Qk):%f"
  local qk_erros
  qk_erros=$(pacman -Qk 2>&1 | grep -v "0 missing files")
  if [[ -z "$qk_erros" ]]; then
    ok "Todos os arquivos íntegros"
  else
    warn "Erros encontrados:"
    echo "$qk_erros"
  fi

  print -P "\n%F{blue}Audit — acessos na semana:%f"
  ausearch -k access -ts week 2>/dev/null || ok "Sem eventos registrados"

  if command -v usbguard &>/dev/null; then
    check "USBGuard rules" usbguard list-rules
  fi

  check "stat críticos" stat /etc/passwd /etc/shadow /etc/sudoers

  print -P "\n%F{blue}Regras Polkit:%f"
  ls -la /etc/polkit-1/rules.d/

  print -P "\n%F{blue}Usuários (UID >= 1000):%f"
  awk -F: '$3 >= 1000 {print $1, $3}' /etc/passwd

  print -P "\n%F{blue}Usuários com UID 0:%f"
  local uid0
  uid0=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
  echo "$uid0"
  [[ $(echo "$uid0" | wc -l) -gt 1 ]] \
    && warn "Mais de um UID 0 detectado!" \
    || ok "UID 0 OK (apenas root)"

  print -P "\n%F{blue}Cron jobs:%f"
  ls -la /etc/cron* /var/spool/cron/ 2>/dev/null || ok "Sem cron jobs"

  print -P "\n%F{blue}Timers systemd:%f"
  systemctl list-timers --all
}

# ─────────────────────────────────────────────────────────

rotina_mensal() {
  header "ROTINA MENSAL"

  local LUKS_DEV
  LUKS_DEV=$(detect_luks)

  section "Sistema"

  print -P "\n%F{blue}Uso do Btrfs:%f"
  check "Btrfs usage" btrfs filesystem usage /

  print -P "\n%F{blue}Subvolumes:%f"
  btrfs subvolume list /

  print -P "\n%F{blue}Balance Btrfs (data > 85%%):%f"
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

  print -P "\n%F{blue}Capabilities atribuídas:%f"
  getcap -r / 2>/dev/null | grep -v "^/proc" || ok "Nenhuma capability extra"

  print -P "\n%F{blue}SUID/SGID — comparando com baseline:%f"
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
  print -P "\n%F{blue}Atualizar baseline de binários críticos? [s/N]%f"
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

  print -P "\n%F{blue}AIDE — atualizando base:%f"
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

  print -P "\n%F{blue}Conexões ativas:%f"
  ss -tupan

  print -P "\n%F{blue}Módulos do kernel:%f"
  lsmod | sort

  print -P "\n%F{blue}Forgejo — logs de hoje:%f"
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
    print -P "\n%F{blue}Flatpak — instalados:%f"
    flatpak list --columns=application,version,installation
  fi

  if $HAS_SNAP; then
    print -P "\n%F{blue}Snap — instalados:%f"
    snap list
  fi

  section "Segurança"

  aa-status --pretty-json 2>/dev/null || aa-status

  pkaction --verbose 2>/dev/null | grep -A5 "implicitany.*yes"

  check_secureboot

  print -P ""
  warn "Para análise de PID:     ausearch -p <PID>"
  warn "Para logs de auditoria:  lnav /var/log/audit/audit.log"
  warn "Para monitoramento:      btop"
}

# ══════════════════════════════════════════════════════════
#  RESUMO
# ══════════════════════════════════════════════════════════
resumo() {
  print -P "\n%F{cyan}═══════════════════════════════%f"
  print -P "%F{green}  RESUMO%f"
  print -P "%F{cyan}═══════════════════════════════%f"
  print -P "  %F{green}✔ Passou:   $PASS%f"
  [[ $FAIL -gt 0 ]] \
    && print -P "  %F{red}✖ Falhou:   $FAIL%f" \
    || print -P "  %F{green}✖ Falhou:   $FAIL%f"
  [[ $WARN -gt 0 ]] \
    && print -P "  %F{yellow}⚠ Avisos:   $WARN%f" \
    || print -P "  %F{green}⚠ Avisos:   $WARN%f"
  $DRY_RUN && print -P "  %F{magenta}⊘ Pulados:  $SKIP%f"
  [[ -n "$LOGFILE" ]] && print -P "  %F{240}Log:        $LOGFILE%f"
  print -P "%F{cyan}═══════════════════════════════%f\n"
  [[ $FAIL -eq 0 ]]
}

# ── Ajuda ─────────────────────────────────────────────────
uso() {
  print -P "\n%F{cyan}Uso:%f sudo rotina [modo] [opções]\n"
  print -P "  %F{green}Modos:%f"
  print -P "    diaria   — atualização + verificações rápidas"
  print -P "    semanal  — diaria + limpeza + integridade + auditoria"
  print -P "    mensal   — semanal + btrfs + LUKS + SUID + AIDE update"
  print -P "    demanda  — investigação e ferramentas manuais\n"
  print -P "  %F{green}Opções:%f"
  print -P "    --dry-run      mostra o que seria feito sem executar destrutivos"
  print -P "    --auto-deps    instala dependências ausentes sem perguntar"
  print -P "    --update-hash  atualiza hash após editar o script"
  print -P "    --install      instala em /usr/local/sbin/rotina + timer opcional\n"
  print -P "  %F{green}Formatos detectados:%f"
  $HAS_PARU    && print -P "    %F{green}✔%f paru"    || print -P "    %F{240}–%f paru"
  $HAS_YAY     && print -P "    %F{green}✔%f yay"     || print -P "    %F{240}–%f yay"
  $HAS_PACMAN  && print -P "    %F{green}✔%f pacman"  || print -P "    %F{240}–%f pacman"
  $HAS_FLATPAK && print -P "    %F{green}✔%f flatpak" || print -P "    %F{240}–%f flatpak"
  $HAS_SNAP    && print -P "    %F{green}✔%f snap"    || print -P "    %F{240}–%f snap"
  [[ -n "$AUR_HELPER" ]] \
    && print -P "    %F{240}AUR helper ativo: $AUR_HELPER%f"
  print -P ""
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
