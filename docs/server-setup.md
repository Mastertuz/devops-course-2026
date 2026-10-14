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
| 2 | Host-only (сеть `HostNetwork`, 192.168.56.0/24, DHCP 192.168.56.1-192.168.56.199) | `enp0s9` | `192.168.56.2/24` (DHCP) | доступ с хоста к службам ВМ напрямую, без NAT (браузер, `devops.local`) |

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
| `devops` | 1001 | `devops`, `sudo`, `users` | по SSH - только ключ ed25519 (`~/.ssh/authorized_keys`, права `700` на `~/.ssh` и `600` на файл); пароль нужен лишь для `sudo` | рабочая учётная запись администратора и владелец публикуемых файлов |

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
- Основной файл конфигурации `/etc/ssh/sshd_config` не изменялся (эталонная копия: `/etc/ssh/sshd_config.backup`); изменения - в дополняющем файле **`/etc/ssh/sshd_config.d/99-hardening.conf`**:

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
| `04-nginx-https` | 19:48 | установлен nginx, ресурс `devops.local` обслуживается по HTTPS (самоподписанный сертификат), HTTP перенаправляется на HTTPS |
| `05-docker-compose` | 14.10.2026 21:41 | установлен Docker Engine, проект `~/app` (приложение + PostgreSQL) запущен через Compose, порт приложения только на `127.0.0.1`, счётчик посещений хранится в именованном томе |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Устанавливаемый пакет | `nginx` 1.28.3 (репозиторий Ubuntu: `sudo apt install -y nginx`) |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, активирована ссылкой в `/etc/nginx/sites-enabled/`; стандартный ресурс отключён (ссылка `default` удалена, файл сохранён) |
| Каталог ресурса | `/var/www/devops-site`; владелец `devops:devops`; права `755` для каталога и `644` для файлов (модель «владелец пишет, веб-сервер читает», права задаёт `rsync --chmod=D755,F644`) |
| Сертификат | `/etc/ssl/certs/devops.crt`, владелец `root`, права `644`; самоподписанный, CN и SAN `devops.local`, срок действия 365 дней (с 05.10.2026 по 05.10.2027) |
| Закрытый ключ | `/etc/ssl/private/devops.key`, владелец `root`, права `600` (читается главным процессом nginx до запуска рабочих, рабочие процессы `www-data` доступа не имеют) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |
| Протоколы TLS | `TLSv1.2`, `TLSv1.3`; заголовок HSTS не используется (самоподписанный сертификат) |

Команда формирования сертификата (`[VM]`):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" -addext "subjectAltName=DNS:devops.local"
```

Конфигурация `/etc/nginx/sites-available/devops-site` состоит из двух блоков `server`: первый (`listen 80`, `server_name devops.local`) возвращает `301 https://$host$request_uri`; второй (`listen 443 ssl`, IPv4 и IPv6) задаёт `ssl_certificate`, `ssl_certificate_key`, `ssl_protocols TLSv1.2 TLSv1.3`, `root /var/www/devops-site`, `index index.html`, `try_files $uri $uri/ =404`, `error_page 404 /404.html` и журналы из таблицы выше.

Порядок применения (`[VM]`; каждое изменение конфигурации применяется командой `sudo nginx -t && sudo systemctl reload nginx`, а не `restart`):

```bash
sudo apt update && sudo apt install -y nginx
sudo mkdir -p /var/www/devops-site && sudo chown -R devops:devops /var/www/devops-site
# создать сертификат (команда выше) и файл /etc/nginx/sites-available/devops-site
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Доставка содержимого (`[Хост]`, нужен `rsync` 3.x; системный `openrsync` в macOS не поддерживает `--chmod`): `scripts/deploy.sh`. Сертификат копируется на хост командой `scp devops:/etc/ssl/certs/devops.crt ~/devops.crt` и указывается клиенту как доверенный (`curl --cacert ~/devops.crt`).

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Способ установки | Docker Engine из официального репозитория `download.docker.com` (файл `/etc/apt/sources.list.d/docker.sources`, `Suites: resolute`, `Architectures: arm64`, ключ `/etc/apt/keyrings/docker.asc`, отпечаток `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`); пакет `docker.io` из репозитория дистрибутива не используется |
| Версии | `docker-ce` 29.9.0, `containerd.io` 2.4.2, `docker-buildx-plugin` 0.38.0, `docker-compose-plugin` 5.6.0 |
| Участники группы `docker` | только `devops` (группа даёт фактически права `root`: контейнер с каталогом `/` хоста, смонтированным на запись; поэтому включаются только учётные записи с правом `sudo`) |
| Проект на сервере | `/home/devops/app` (владелец `devops:devops`, права 755); исходный код доставляется с хоста командой `rsync -avz --delete --exclude=.env app/ devops:app/`; имя проекта Compose `app` |
| Файл с секретами | `/home/devops/app/.env`, владелец `devops:devops`, права 600; создаётся только на сервере из шаблона `.env.example`, пароль СУБД формируется командой `openssl rand -hex 16`; в репозиторий не добавляется (`.gitignore`), в образ не попадает (`.dockerignore`) |
| Образы | `devops-app:1.0` (на базе `python:3.12-slim`, процесс от пользователя `app`), `postgres:16-alpine` (тег фиксирует основную версию: формат данных несовместим между основными версиями) |
| Контейнеры | `app-app-1` (приложение), `app-db-1` (СУБД, проверка `pg_isready`, состояние `healthy`), политика перезапуска `unless-stopped`; приложение стартует после успешной проверки СУБД (`condition: service_healthy`) |
| Публикуемые порты | приложение: `127.0.0.1:5000 -> 5000/tcp` (только локальный адрес, доступ извне через Nginx); СУБД: порт не публикуется, доступна приложению по имени `db` в сети проекта |
| Сеть | пользовательская сеть `app_backend` (драйвер `bridge`), встроенный DNS разрешает имена сервисов |
| Именованные тома | `app_db_data` (драйвер `local`, `/var/lib/docker/volumes/app_db_data/_data`) - данные PostgreSQL; сохраняется командой `docker compose down`, удаляется командой `docker compose down -v` |
| Обратный прокси-сервер | в блок `server` с `listen 443 ssl` файла `/etc/nginx/sites-available/devops-site` добавлено `location /app/` с `proxy_pass http://127.0.0.1:5000/;` и заголовками `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`; статический ресурс (`location /`) сохранён |

Установка Docker Engine (`[VM]`):

```bash
sudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# сверить отпечаток: gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops        # затем новая SSH-сессия
docker run --rm hello-world
```

Запуск проекта (`[VM]`):

```bash
cd ~/app
cp .env.example .env && chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps                      # app-db-1 (healthy)
```

Подключение приложения к Nginx (`[VM]`; фрагмент добавляется в блок HTTPS, затем `sudo nginx -t && sudo systemctl reload nginx`):

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Особенность публикации портов: Docker перенаправляет пакеты к опубликованному порту правилами `iptables` до обработки правилами UFW, поэтому порт, опубликованный на `0.0.0.0` (например, `-p 5001:5000`), доступен из сети независимо от политики `deny incoming`. Порт приложения публикуется только на `127.0.0.1`, порт СУБД не публикуется.
