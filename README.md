# rotina.sh — Script de Manutenção e Segurança

## 📌 Visão Geral

O `rotina.sh` é um script avançado de automação para **manutenção, auditoria e segurança de sistemas Linux** (especialmente Arch Linux e derivados).

Ele organiza tarefas em diferentes níveis de periodicidade, permitindo executar rotinas de forma segura, rastreável e padronizada.

Quer ajudar o Projeto?
[Bug Bounty](https://github.com/HGBits/Security-Chain/blob/c7d59d5b4ed81dce6a658316577836b768842424/BugBounty.md)
---

## ⚙️ Funcionalidades Principais

* ✔ Atualização automática do sistema
* ✔ Verificação de integridade do próprio script (SHA-256)
* ✔ Auditoria de segurança (logs, autenticação, AppArmor, auditd)
* ✔ Limpeza de pacotes e cache
* ✔ Monitoramento de serviços e portas
* ✔ Gestão de snapshots (Btrfs + Snapper)
* ✔ Verificação de integridade com AIDE
* ✔ Auditoria de permissões e arquivos críticos
* ✔ Suporte a LUKS, TPM2 e Secure Boot
* ✔ Modo **dry-run** (simulação segura)

---

## 🚀 Uso

```bash
sudo rotina.zsh [modo] [opções]
```

### Modos disponíveis

| Modo      | Descrição                               |
| --------- | --------------------------------------- |
| `diaria`  | Atualizações + verificações rápidas     |
| `semanal` | Inclui diária + limpeza + auditorias    |
| `mensal`  | Inclui semanal + verificações profundas |
| `demanda` | Ferramentas de investigação manual      |

### Opções

| Opção           | Descrição                              |
| --------------- | -------------------------------------- |
| `--dry-run`     | Simula ações destrutivas sem executar  |
| `--update-hash` | Atualiza hash de integridade do script |

---

## 🔐 Segurança: Verificação de Integridade

O script utiliza SHA-256 para detectar alterações:

* Hash armazenado em:

  ```
  /etc/rotina.sha256
  ```
* Se o script for modificado:

  * Execução é **interrompida**
  * Exige confirmação manual via:

    ```bash
    sudo rotina.zsh --update-hash
    ```

---

## 🧱 Estrutura Interna

### 1. Parsing de Argumentos

Interpreta:

* Modo de execução
* Flags (`--dry-run`, `--update-hash`)

---

### 2. Sistema de Logging

* Logs salvos em:

  ```
  /var/log/rotina/YYYY-MM-DD-modo.log
  ```
* Remove cores ANSI para facilitar leitura posterior

---

### 3. Helpers

Funções utilitárias:

* `header()` → título da rotina
* `section()` → separação por blocos
* `ok()`, `warn()`, `err()` → status visual
* `destrut()` → executa comandos destrutivos com suporte a dry-run
* `check()` → comandos somente leitura

---

### 4. Verificação de Dependências

Cada modo possui comandos obrigatórios:

Exemplo:

```bash
DEPS_MAP[diaria]="paru systemctl snapper ..."
```

Se faltar algo → execução é abortada.

---

## 🔄 Rotinas

---

### 📅 Rotina Diária

**Objetivo:** manutenção leve + monitoramento rápido

#### Sistema:

* Atualização (`paru -Syu`)
* Serviços com falha (`systemctl`)
* Snapshots recentes
* Status do ZRAM

#### Segurança:

* Falhas de login (`ausearch`)
* Logs AppArmor (DENIED)
* Histórico de logins (`last`)
* Portas abertas (`ss`)
* Eventos USB (`usbguard`)

---

### 📆 Rotina Semanal

**Objetivo:** limpeza + auditoria intermediária

#### Sistema:

* Snapshot pré-manutenção
* Limpeza de cache (`paru`, `paccache`)
* Remoção de pacotes órfãos
* Limpeza de Flatpak

#### Segurança:

* Verificação AIDE
* Perfis AppArmor em modo `complain`
* Integridade de pacotes (`pacman -Qk`)
* Logs auditd
* Permissões de arquivos críticos
* Verificação de usuários suspeitos (UID 0)
* Cron jobs e timers systemd

---

### 🗓️ Rotina Mensal

**Objetivo:** auditoria profunda + integridade estrutural

#### Sistema:

* Uso do Btrfs
* Balanceamento de disco
* Verificação Secure Boot

#### Segurança:

* Dump e backup do LUKS
* Checagem TPM2
* Regras auditd
* Capabilities do sistema
* Monitoramento de arquivos SUID/SGID
* Atualização da base AIDE

---

### 🔍 Rotina Sob Demanda

**Objetivo:** investigação manual

Inclui:

* Conexões ativas
* Módulos do kernel
* Logs de serviços específicos (ex: Forgejo)
* Status AppArmor
* Regras Polkit inseguras
* Estado do Secure Boot

---

## 🧪 Modo Dry-Run

Executa o script **sem alterar o sistema**:

```bash
sudo rotina.zsh semanal --dry-run
```

* Comandos destrutivos são exibidos mas não executados
* Contador de ações puladas (`SKIP`) é incrementado

---

## 📊 Resumo Final

Ao final de cada execução:

```
✔ Passou:   X
✖ Falhou:   Y
⚠ Avisos:   Z
⊘ Pulados:  N (se dry-run)
```

---

## 📁 Arquivos Importantes

| Caminho              | Descrição              |
| -------------------- | ---------------------- |
| `/var/log/rotina/`   | Logs das execuções     |
| `/etc/rotina.sha256` | Hash de integridade    |
| `/var/lib/aide/`     | Base do AIDE           |
| `/tmp/suid-*.txt`    | Snapshot atual de SUID |

---

## ⚠️ Boas Práticas

* Sempre rodar como `root`
* Testar com `--dry-run` antes de usar em produção
* Revisar logs regularmente
* Manter dependências atualizadas
* Fazer backup antes da rotina mensal

---

## 🧠 Observações

* Projetado para sistemas com:

  * Btrfs
  * Snapper
  * AppArmor
  * auditd
* Pode exigir ajustes em outras distribuições

---

## ✅ Conclusão

O `rotina.zsh` é uma solução robusta para:

* Automatizar manutenção
* Melhorar segurança
* Detectar anomalias
* Padronizar auditorias

Ideal para usuários avançados e administradores que desejam **controle total e visibilidade do sistema**.
