#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

# На macOS системный rsync (openrsync) не поддерживает --chmod=D...,F...:
# ищем rsync 3.x от Homebrew раньше системного.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

REMOTE="devops"                       # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"

# Репозиторий определяется по расположению скрипта, а не по текущему каталогу:
# сценарий работает одинаково при запуске из любого каталога.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=0
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN=1 ;;
    *)         echo "Использование: $0 [--dry-run]" >&2; exit 2 ;;
esac

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] \
    || die "файл site/index.html отсутствует: доставка отменена (иначе --delete удалил бы главную страницу на сервере)"

# незафиксированные изменения отслеживаемых файлов (рабочая копия и индекс)
# и любые новые неотслеживаемые файлы внутри site/
if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no)" ]] \
   || [[ -n "$(git -C "${REPO_ROOT}" status --porcelain -- site/)" ]]; then
    die "в репозитории есть незафиксированные изменения: доставка отменена (сначала git commit)"
fi

# rsync 3.x обязателен: openrsync молча игнорирует --chmod
RSYNC_VERSION="$(rsync --version 2>&1 || true)"
RSYNC_VERSION="${RSYNC_VERSION%%$'\n'*}"
[[ "${RSYNC_VERSION}" != *openrsync* ]] \
    || die "найден openrsync (${RSYNC_VERSION}); установите rsync 3.x: brew install rsync"

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
#    за один запуск - одно SSH-соединение (отдельных проверок по SSH нет);
#    BatchMode=yes: при непригодном ключе пароль не запрашивается, сценарий завершается ошибкой
RSYNC_OPTS=(-avz --delete --chmod=D755,F644 -e "ssh -o BatchMode=yes -o ConnectTimeout=5")
(( DRY_RUN )) && RSYNC_OPTS+=(--dry-run)
rsync "${RSYNC_OPTS[@]}" "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run - завершение с кодом 0 без проверки доступности
if (( DRY_RUN )); then
    echo "Пробный запуск завершён: состояние сервера не изменено."
    exit 0
fi

# 5. Проверка доступности ${SITE_URL}: сертификат проверяется (без -k), HTTP-ошибка (-f) = неуспех
curl -fsS --max-time 10 --cacert "${CA_CERT}" -o /dev/null "${SITE_URL}" \
    || die "ресурс ${SITE_URL} недоступен после доставки"

echo "Доставлено: $(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
