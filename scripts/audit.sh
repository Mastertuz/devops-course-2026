#!/usr/bin/env bash
# Аудит конфигурации devops-vm. Запускается на виртуальной машине: sudo bash audit.sh
# Код возврата: 0 - все проверки пройдены, 1 - есть непройденные проверки.
# Порог срока действия сертификата (дней) можно переопределить: sudo env CERT_MIN_DAYS=400 bash audit.sh
set -uo pipefail

PASS=0; FAIL=0
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"

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

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
