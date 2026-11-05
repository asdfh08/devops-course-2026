#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"   # порог для проверки срока действия сертификата

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
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2; exit}')"
check "Порт SSH отличен от 22 (текущий: ${SSH_PORT:-нет})" "yes" \
    "$([[ -n "$SSH_PORT" && "$SSH_PORT" == "22" ]] && echo no || echo yes)"
check "Число попыток аутентификации равно 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
check "Политика по умолчанию для входящего трафика — deny" "deny" \
    "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "    %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна" "ok" \
    "$(sudo nginx -t >/dev/null 2>&1 && echo ok || echo error)"
check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дн." "ok" \
    "$(openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in /etc/ssl/certs/devops.crt >/dev/null 2>&1 && echo ok || echo expires)"
WRITABLE="$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l | tr -d ' ')"
KEY_MODE="$(sudo stat -c '%a' /etc/ssl/private/devops.key)"
check "Нет файлов ресурса с записью для всех, права ключа 600" "0/600" "${WRITABLE}/${KEY_MODE}"

echo "[5] Контейнеризация"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" \
    "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo 'нет контейнера')"
EXPOSED="$(ss -tlnH | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | tr '\n' ' ' | sed 's/ $//')"
check "Порты 5000 и 5432 — только на 127.0.0.1" "нет" "${EXPOSED:-нет}"
check "Права файла ~/app/.env равны 600" "600" "$(stat -c '%a' "$HOME/app/.env" 2>/dev/null || echo 'нет файла')"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
