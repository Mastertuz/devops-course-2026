#!/usr/bin/env bash
# Аудит конфигурации devops-vm. Запускается на виртуальной машине: sudo bash audit.sh
# Код возврата: 0 - все проверки пройдены, 1 - есть непройденные проверки.
# Порог срока действия сертификата (дней) можно переопределить: sudo env CERT_MIN_DAYS=400 bash audit.sh
# Каталог проекта контейнеров по умолчанию - ~/app пользователя, запустившего sudo; переопределение: APP_DIR=/путь
# Раздел [6] (контрольная работа № 2): проект ~/kr2, порт варианта 8002, ресурс kr2; переопределение: KR2_DIR, KR2_PORT, KR2_SITE
set -uo pipefail

PASS=0; FAIL=0
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
# при запуске через sudo переменная HOME указывает на каталог root, поэтому домашний каталог берётся по имени пользователя
APP_DIR="${APP_DIR:-$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)/app}"
# параметры контрольной работы № 2 (вариант 2: порт 8002)
KR2_DIR="${KR2_DIR:-$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)/kr2}"
KR2_PORT="${KR2_PORT:-8002}"
KR2_SITE="${KR2_SITE:-kr2}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён"        "no"  "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no"  "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# TODO 1: порт SSH отличен от 22 (при нескольких директивах port ни одна не должна быть равна 22)
check "Порт SSH отличен от 22"             "yes" "$(sudo sshd -T | awk '/^port/{if ($2==22) bad=1} END{print bad ? "no" : "yes"}')"
# TODO 2: maxauthtries равно 3
check "MaxAuthTries равно 3"               "3"   "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# TODO 3: политика по умолчанию для входящего трафика - deny
check "Политика по умолчанию для входящего трафика - deny" "deny" "$(sudo ufw status verbose | grep Default | awk '{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx синтаксически корректна (nginx -t)" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
check "Сертификат истекает не ранее чем через ${CERT_MIN_DAYS} дн." "0" \
    "$(openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; echo $?)"
check "В каталоге ресурса нет файлов, доступных для записи всем; права ключа равны 600" "0 600" \
    "$(find /var/www/devops-site -perm -o+w | wc -l | tr -d ' ') $(sudo stat -c '%a' /etc/ssl/private/devops.key)"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
check "Порты 5000 и 5432 не прослушиваются на адресах, кроме 127.0.0.1" "0" \
    "$(ss -tln | awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:/ {n++} END {print n+0}')"
check "Права файла .env равны 600" "600" "$(stat -c '%a' "${APP_DIR}/.env" 2>/dev/null)"

echo "[6] Контрольная работа № 2"
# контейнер определяется по имени сервиса, а не по имени, сформированному Compose
KR2_REDIS_ID="$(docker compose --project-directory "${KR2_DIR}" ps -q redis 2>/dev/null)"
check "Контейнер сервиса redis в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' "${KR2_REDIS_ID}" 2>/dev/null)"
# адреса публикации порта (IPv4 и IPv6), без номера порта; ожидается единственный адрес 127.0.0.1
check "Порт ${KR2_PORT} опубликован только на адресе 127.0.0.1" "127.0.0.1" \
    "$(docker compose --project-directory "${KR2_DIR}" port app "${KR2_PORT}" 2>/dev/null | sed 's/:[0-9]*$//' | sort -u | paste -sd, -)"
check "Права файла ${KR2_DIR}/.env равны 600" "600" "$(stat -c '%a' "${KR2_DIR}/.env" 2>/dev/null)"
check "Сертификат kr2.crt истекает не ранее чем через ${CERT_MIN_DAYS} дн." "0" \
    "$(openssl x509 -in /etc/ssl/certs/kr2.crt -noout -checkend $((CERT_MIN_DAYS * 86400)) >/dev/null 2>&1; echo $?)"
check "Ресурс ${KR2_SITE} активирован (ссылка в ${NGINX_ENABLED_DIR})" "yes" \
    "$([[ -L "${NGINX_ENABLED_DIR}/${KR2_SITE}" ]] && echo yes || echo no)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
