#!/usr/bin/env zsh

# ══════════════════════════════════════════════════════════
#  rotina.zsh — Manutenção e segurança do sistema
#  Uso: sudo rotina.zsh [diaria|semanal|mensal|demanda] [--dry-run]
#       sudo rotina.zsh --update-hash
# ══════════════════════════════════════════════════════════

# ── Parsing ───────────────────────────────────────────────
MODO=""
DRY_RUN=false
UPDATE_HASH=false

for arg in "$@"; do
  case $arg in
    diaria|semanal|mensal|demanda) MODO=$arg ;;
    --dry-run)     DRY_RUN=true ;;
    --update-hash) UPDATE_HASH=true ;;
  esac
done

MODO=${MODO:-help}

# ── Configuração ──────────────────────────────────────────
LOG_DIR="/var/log/rotina"
HASH_FILE="/etc/rotina.sha256"
SCRIPT_PATH=$(realpath "$0")
SUID_ANTERIOR="$LOG_DIR/suid-anterior.txt"
TIMEOUT_LENTO=300   # btrfs balance — 5 min
TIMEOUT_MEDIO=120   # find SUID    — 2 min

typeset -i PASS=0 FAIL=0 WARN=0 SKIP=0

# ── Logging ───────────────────────────────────────────────
if [[ "$MODO" != "help" && "$UPDATE_HASH" == false ]]; then
  mkdir -p "$LOG_DIR"
  LOGFILE="$LOG_DIR/$(date +%F)-${MODO}.log"
  exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOGFILE")) 2>&1
  print -P "%F{240}► Log: $LOGFILE%f"
fi

# ── Helpers ───────────────────────────────────────────────
header() {
  print -P "\n%F{cyan}═══════════════════════════════%f"
  print -P "%F{green}  $1%f"
  print -P "%F{240}  $(date '+%Y-%m-%d %H:%M:%S')%f"
  print -P "%F{cyan}═══════════════════════════════%f\n"
}

section() {
  print -P "\n%F{yellow}► $1 %F{240}[$(date +%H:%M:%S)]%f"
}

ok()   { print -P "%F{green}  ✔ $1%f" }
warn() { print -P "%F{yellow}  ⚠ $1%f" }
err()  { print -P "%F{red}  ✖ $1%f" }

# Comando destrutivo — pulado em dry-run
destrut() {
  local label=$1; shift
  if $DRY_RUN; then
    print -P "%F{magenta}  [DRY-RUN]%f $*"
    ((SKIP++))
    return 0
  fi
  "$@"
  local rc=$?
  [[ $rc -eq 0 ]] && { ok "$label"; ((PASS++)); } || { err "$label falhou (rc=$rc)"; ((FAIL++)); }
  return $rc
}

# Verificação read-only — sempre executa
check() {
  local label=$1; shift
  "$@"
  local rc=$?
  [[ $rc -eq 0 ]] && ((PASS++)) || { err "$label falhou (rc=$rc)"; ((FAIL++)); }
  return $rc
}

# ── Integridade do script ─────────────────────────────────
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
    ok "Integridade do script verificada"; ((PASS++))
  else
    err "INTEGRIDADE COMPROMETIDA — hash não confere!"
    err "Se editou o script legitimamente: sudo rotina.zsh --update-hash"
    exit 1
  fi
}

# ── Dependências ──────────────────────────────────────────
typeset -A DEPS_MAP
DEPS_MAP[diaria]="paru systemctl snapper zramctl ausearch journalctl last ss"
DEPS_MAP[semanal]="paru paccache flatpak snapper aide aa-status pacman ausearch usbguard stat awk systemctl"
DEPS_MAP[mensal]="btrfs sbctl cryptsetup auditctl getcap find aide"
DEPS_MAP[demanda]="ss lsmod journalctl aa-status mokutil"

check_deps() {
  [[ -z "${DEPS_MAP[$MODO]}" ]] && return
  local missing=()
  for cmd in ${=DEPS_MAP[$MODO]}; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Dependências ausentes: ${missing[*]}"
    exit 1
  fi
  ok "Dependências OK"
}

# ── Detecção LUKS ─────────────────────────────────────────
detect_luks() {
  lsblk -rno NAME,TYPE | awk '$2=="part"{print $1}' | while read -r dev; do
    cryptsetup isLuks "/dev/$dev" 2>/dev/null && echo "/dev/$dev" && return
  done
}

# ══════════════════════════════════════════════════════════
#  ROTINAS
# ══════════════════════════════════════════════════════════

rotina_diaria() {
  header "ROTINA DIÁRIA"

  section "Sistema"

  print -P "\n%F{blue}Atualização do sistema:%f"
  destrut "Atualização" paru -Syu --noconfirm

  print -P "\n%F{blue}Serviços com falha:%f"
  local failed
  failed=$(systemctl --failed --no-legend 2>/dev/null)
  if [[ -z "$failed" ]]; then
    ok "Nenhum serviço com falha"; ((PASS++))
  else
    warn "Serviços com falha:"; ((WARN++))
    echo "$failed"
  fi

  print -P "\n%F{blue}Últimos snapshots:%f"
  snapper -c root list | tail -3

  print -P "\n%F{blue}ZRAM:%f"
  zramctl

  section "Segurança"

  print -P "\n%F{blue}Falhas de autenticação hoje:%f"
  local auth_fail
  auth_fail=$(ausearch -m USER_AUTH,USER_LOGIN -sv no -ts today 2>/dev/null)
  if [[ -z "$auth_fail" ]]; then
    ok "Sem falhas de autenticação"; ((PASS++))
  else
    warn "Falhas detectadas:"; ((WARN++))
    echo "$auth_fail"
  fi

  print -P "\n%F{blue}AppArmor DENIED hoje:%f"
  local aa_denied
  aa_denied=$(journalctl -b --since today 2>/dev/null | grep 'apparmor="DENIED"')
  if [[ -z "$aa_denied" ]]; then
    ok "Nenhum DENIED"; ((PASS++))
  else
    warn "AppArmor DENIED:"; ((WARN++))
    echo "$aa_denied"
  fi

  print -P "\n%F{blue}Últimos logins:%f"
  last -n 20

  print -P "\n%F{blue}Tentativas falhas de login:%f"
  lastb -n 20 2>/dev/null || warn "lastb indisponível"

  print -P "\n%F{blue}Portas abertas:%f"
  ss -tulnp

  print -P "\n%F{blue}USBGuard hoje:%f"
  local usb_events
  usb_events=$(journalctl -u usbguard --since today 2>/dev/null | grep -i "block\|reject\|DENY")
  if [[ -z "$usb_events" ]]; then
    ok "Sem eventos USBGuard"; ((PASS++))
  else
    echo "$usb_events"
  fi
}

# ─────────────────────────────────────────────────────────

rotina_semanal() {
  header "ROTINA SEMANAL"

  section "Sistema"

  print -P "\n%F{blue}Snapshot pré-manutenção:%f"
  destrut "Snapshot" snapper -c root create --description "pre-manutencao-$(date +%F)"

  print -P "\n%F{blue}Limpeza cache paru:%f"
  destrut "Cache paru" paru -Sc --noconfirm

  print -P "\n%F{blue}Cache de pacotes (manter 2):%f"
  destrut "paccache" paccache -rk2

  print -P "\n%F{blue}Flatpaks não utilizados:%f"
  destrut "Flatpak cleanup" flatpak uninstall --unused -y

  print -P "\n%F{blue}Órfãos:%f"
  local orfaos
  orfaos=$(paru -Qtdq 2>/dev/null)
  if [[ -n "$orfaos" ]]; then
    echo "$orfaos"
    if $DRY_RUN; then
      print -P "%F{magenta}  [DRY-RUN]%f paru -Rns --noconfirm <orphans>"
      ((SKIP++))
    else
      echo "$orfaos" | paru -Rns --noconfirm -
      local rc=$?
      [[ $rc -eq 0 ]] && { ok "Órfãos removidos"; ((PASS++)); } \
                      || { err "Remoção falhou (rc=$rc)"; ((FAIL++)); }
    fi
  else
    ok "Sem órfãos"; ((PASS++))
  fi

  section "Segurança"

  print -P "\n%F{blue}AIDE — verificação de integridade:%f"
  aide --check 2>&1 | tee "$LOG_DIR/aide-$(date +%F).log"
  local aide_rc=${pipestatus[1]}
  [[ $aide_rc -eq 0 ]] && { ok "AIDE OK"; ((PASS++)); } \
                       || { warn "AIDE reportou mudanças (rc=$aide_rc)"; ((WARN++)); }

  print -P "\n%F{blue}AppArmor — perfis em complain:%f"
  local complain
  complain=$(aa-status 2>/dev/null | grep complain)
  if [[ -z "$complain" ]]; then
    ok "Nenhum perfil em complain"; ((PASS++))
  else
    warn "Perfis em complain:"; ((WARN++))
    echo "$complain"
  fi

  print -P "\n%F{blue}Arquivos com erros (pacman -Qk):%f"
  local qk_erros
  qk_erros=$(pacman -Qk 2>&1 | grep -v "0 missing files")
  if [[ -z "$qk_erros" ]]; then
    ok "Todos os arquivos íntegros"; ((PASS++))
  else
    warn "Erros encontrados:"; ((WARN++))
    echo "$qk_erros"
  fi

  print -P "\n%F{blue}Audit — acessos na semana:%f"
  ausearch -k access -ts week 2>/dev/null || ok "Sem eventos registrados"

  print -P "\n%F{blue}Regras USBGuard:%f"
  check "USBGuard rules" usbguard list-rules

  print -P "\n%F{blue}Permissões de arquivos críticos:%f"
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
    && { warn "Mais de um UID 0 detectado!"; ((WARN++)); } \
    || ((PASS++))

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

  print -P "\n%F{blue}Secure Boot — status:%f"
  check "sbctl status" sbctl status

  print -P "\n%F{blue}Secure Boot — binários não assinados:%f"
  local unsigned
  unsigned=$(sbctl verify 2>&1 | grep "not signed")
  if [[ -z "$unsigned" ]]; then
    ok "Todos assinados"; ((PASS++))
  else
    warn "Não assinados:"; ((WARN++))
    echo "$unsigned"
  fi

  section "Segurança"

  if [[ -n "$LUKS_DEV" ]]; then
    print -P "\n%F{blue}LUKS dump ($LUKS_DEV):%f"
    check "LUKS dump" cryptsetup luksDump "$LUKS_DEV"

    print -P "\n%F{blue}Backup do header LUKS:%f"
    local backup="$LOG_DIR/luks-header-$(date +%F).bin"
    destrut "LUKS backup" cryptsetup luksHeaderBackup "$LUKS_DEV" \
      --header-backup-file "$backup"
    [[ -f "$backup" ]] && ok "Salvo em $backup"
  else
    warn "Dispositivo LUKS não detectado automaticamente"; ((WARN++))
  fi

  print -P "\n%F{blue}TPM2 — chave pública:%f"
  systemd-cryptenroll --tpm2-device=auto --print-pubkey=tpm2 2>/dev/null \
    || warn "TPM2 não configurado"

  print -P "\n%F{blue}Regras auditd ativas:%f"
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
      ok "Sem mudanças em SUID/SGID"; ((PASS++))
    else
      warn "Mudanças detectadas:"; ((WARN++))
      echo "$diff_out"
    fi
  else
    warn "Sem baseline anterior — criado agora para próximo mês"; ((WARN++))
  fi
  cp "$suid_atual" "$SUID_ANTERIOR"

  print -P "\n%F{blue}AIDE — atualizando base:%f"
  destrut "AIDE update" sh -c \
    'aide --update && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db'
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
  journalctl -u forgejo --since today

  section "Segurança"

  print -P "\n%F{blue}AppArmor — status:%f"
  aa-status --pretty-json 2>/dev/null || aa-status

  print -P "\n%F{blue}Polkit — ações com implicit any=yes:%f"
  pkaction --verbose 2>/dev/null | grep -A5 "implicitany.*yes"

  print -P "\n%F{blue}Secure Boot:%f"
  mokutil --sb-state

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
  print -P "\n%F{cyan}Uso:%f sudo rotina.zsh [modo] [opcoes]\n"
  print -P "  %F{green}Modos:%f"
  print -P "    diaria   — atualizacao + verificacoes rapidas"
  print -P "    semanal  — diaria + limpeza + integridade + auditoria"
  print -P "    mensal   — semanal + btrfs + LUKS + SUID + AIDE update"
  print -P "    demanda  — investigacao e ferramentas manuais\n"
  print -P "  %F{green}Opcoes:%f"
  print -P "    --dry-run      mostra o que seria feito sem executar destrutivos"
  print -P "    --update-hash  atualiza hash de integridade apos editar o script\n"
}

# ══════════════════════════════════════════════════════════
#  ENTRY POINT
# ══════════════════════════════════════════════════════════
[[ "$UPDATE_HASH" == true ]] && cmd_update_hash

if [[ "$MODO" != "help" ]]; then
  check_integrity
  check_deps
  $DRY_RUN && warn "Modo DRY-RUN ativo — destrutivos nao serao executados\n"
fi

case $MODO in
  diaria)  rotina_diaria;                                resumo ;;
  semanal) rotina_diaria; rotina_semanal;                resumo ;;
  mensal)  rotina_diaria; rotina_semanal; rotina_mensal; resumo ;;
  demanda) rotina_demanda;                               resumo ;;
  *)       uso ;;
esac
