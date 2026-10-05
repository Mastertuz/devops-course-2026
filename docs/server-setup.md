# Конфигурация виртуальной машины devops-vm

Документ описывает конфигурацию так, чтобы машину можно было восстановить с нуля (снимок `01-clean-install`) за 10 минут и использовать как исходные данные для Ansible-роли (практическая работа № 11). Команды выполняются на сервере (`[VM]`) или на хостовой системе (`[Хост]`).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Средство виртуализации | Oracle VirtualBox 7.2 (хост: macOS, Apple Silicon, arm64) |
| Наименование | `devops-vm` |
| Гостевая система | Ubuntu Server 26.04.1 LTS (arm64), ядро 7.0.0-38-generic |
| Оперативная память | 2048 МБ |
| Количество ядер процессора | 2 |
| Диск | 25 ГБ (25600 МБ), динамически расширяемый (VDI), разметка `Use an entire disk` |
| Встроенное ПО | EFI |
| Имя узла | `devops-vm` (FQDN `devops-vm.devops.local`) |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | `enp0s8` | `10.0.2.15/24` (DHCP VirtualBox) | доступ ВМ в Интернет (репозитории пакетов); входящие соединения только через проброс портов |
| 2 | Host-only (сеть `HostNetwork`, 192.168.56.0/24, DHCP 192.168.56.1–192.168.56.199) | `enp0s9` | `192.168.56.2/24` (DHCP) | доступ с хоста к службам ВМ напрямую, без NAT (браузер, `devops.local`) |

- Оба интерфейса получают адреса по DHCP из штатной конфигурации установщика: `/etc/netplan/00-installer-config.yaml` (дополнительных файлов netplan не создавалось).
- Адрес Host-only выдаётся DHCP-сервером и может измениться; фактический адрес проверяется командой `ip -brief address`.
- Разрешение имени `devops.local` на хосте: запись `192.168.56.2   devops.local` в `/etc/hosts` хостовой системы (`[Хост]`: `echo "192.168.56.2   devops.local" | sudo tee -a /etc/hosts`).
- Имя узла (`[VM]`):

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f        # devops-vm.devops.local
```

## 3. Правило проброса портов

Адаптер 1 (NAT), правило `ssh`:

| Параметр | Значение |
|---|---|
| Протокол | TCP |
| Адрес хоста / порт хоста | `127.0.0.1` / `2222` |
| Адрес гостя / порт гостя | не задан / `2222` |

Порт гостевой системы равен порту, на котором слушает `sshd` (см. п. 5). Задание на работающей машине (`[Хост]`):

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh                       # если правило уже есть
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | UID | Группы | Способ аутентификации | Назначение |
|---|---|---|---|---|
| `vasil` | 1000 | `vasil`, `adm`, `cdrom`, `sudo`, `dip`, `plugdev`, `users`, `lxd` | пароль (консоль виртуальной машины); по SSH не допускается (`AllowUsers devops`) | учётная запись установщика, резервный вход через консоль |
| `devops` | 1001 | `devops`, `sudo`, `users` | по SSH — только ключ ed25519 (`~/.ssh/authorized_keys`, права `700` на `~/.ssh` и `600` на файл); пароль нужен лишь для `sudo` | рабочая учётная запись администратора и владелец публикуемых файлов |

Создание `devops` (`[VM]`):

```bash
sudo adduser devops
sudo usermod -aG sudo devops
```

Ключ (`[Хост]`): отдельная пара ed25519 без парольной фразы, не связанная с ключом для системы контроля версий.

```bash
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

Блок `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

- Пакет: `openssh-server` (устанавливается вручную: `sudo apt install -y openssh-server`).
- Порт: **2222**.
- Основной файл конфигурации `/etc/ssh/sshd_config` не изменялся (эталонная копия: `/etc/ssh/sshd_config.backup`); изменения — в дополняющем файле **`/etc/ssh/sshd_config.d/99-hardening.conf`**:

| Директива | Значение |
|---|---|
| `Port` | `2222` |
| `PermitRootLogin` | `no` |
| `PasswordAuthentication` | `no` |
| `PubkeyAuthentication` | `yes` |
| `PermitEmptyPasswords` | `no` |
| `MaxAuthTries` | `3` |
| `LoginGraceTime` | `30` |
| `AllowUsers` | `devops` |
| `X11Forwarding` | `no` |
| `ClientAliveInterval` / `ClientAliveCountMax` | `300` / `2` |

- Активация по сокету отключена (иначе порт задаётся юнитом `ssh.socket`, а не директивой `Port`); служба запускается как `ssh.service`.
- Конфликтующих файлов в `/etc/ssh/sshd_config.d/` нет (файл `50-cloud-init.conf` в данном образе отсутствует).

Порядок применения (`[VM]`): файл создаётся, конфигурация проверяется до перезапуска, сессию не закрывать до успешного подключения из второго терминала.

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf       # содержимое по таблице выше
sudo sshd -t && echo "Конфигурация корректна"
sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
sudo systemctl disable --now ssh.socket && sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                                 # 0.0.0.0:2222
```

После этого правило проброса из п. 3 переводится на гостевой порт 2222.

## 6. Правила межсетевого экрана

Утилита `ufw`, состояние `active`, журналирование `medium`.

| Параметр | Значение |
|---|---|
| Политика для входящего трафика | `deny` |
| Политика для исходящего трафика | `allow` |
| Политика для пересылаемого трафика | `disabled` (routed) |

| Порт | Действие | Комментарий |
|---|---|---|
| `2222/tcp` | `LIMIT IN` (IPv4 и IPv6) | `SSH rate-limited` (блокировка источника при 6 и более соединениях за 30 с) |
| `80/tcp` | `ALLOW IN` (IPv4 и IPv6) | `HTTP` |
| `443/tcp` | `ALLOW IN` (IPv4 и IPv6) | `HTTPS` |

Порядок применения (`[VM]`; разрешающее правило для управляющего порта создаётся до включения экрана):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 80/tcp  comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw delete allow 2222/tcp
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw logging medium
sudo ufw status verbose
```

## 7. Снимки состояния

| Наименование | Момент создания (МСК, 05.10.2026) | Состояние |
|---|---|---|
| `01-clean-install` | 17:31 | чистая установка Ubuntu Server 26.04.1, установлен `openssh-server`, система обновлена, оба адаптера получили адреса |
| `02-keys-configured` | 18:24 | создан пользователь `devops`, настроена аутентификация по ключу, добавлен `~/.ssh/config` |
| `03-ssh-hardened` | 18:35 | применён `99-hardening.conf` (порт 2222, запрет `root` и паролей), правило проброса `2222 → 2222` |
