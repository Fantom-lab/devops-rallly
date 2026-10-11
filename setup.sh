#!/bin/sh
set -e

echo "=== Rallly setup ==="

# Проверка необходимых команд
for cmd in docker git openssl curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[FAIL] Не найдена команда: $cmd" >&2
        exit 1
    fi
done

# Проверка Docker Compose
if ! docker compose version >/dev/null 2>&1; then
    echo "[FAIL] Docker Compose недоступен." >&2
    exit 1
fi

# Создание .env только при первом запуске
if [ ! -f .env ]; then
    echo "[INFO] Создание .env..."

    cp .env.example .env

    PG_PASS=$(openssl rand -hex 16)
    SEC_PASS=$(openssl rand -hex 16)
    AUTH_SECRET=$(openssl rand -hex 32)

    sed -i "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$PG_PASS/" .env
    sed -i "s/^SECRET_PASSWORD=$/SECRET_PASSWORD=$SEC_PASS/" .env

    if grep -q '^NEXTAUTH_SECRET=' .env; then
        sed -i "s|^NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=$AUTH_SECRET|" .env
    else
        echo "NEXTAUTH_SECRET=$AUTH_SECRET" >> .env
    fi

    if grep -q '^NEXTAUTH_URL=' .env; then
        sed -i 's|^NEXTAUTH_URL=.*|NEXTAUTH_URL=http://localhost:3000|' .env
    else
        echo "NEXTAUTH_URL=http://localhost:3000" >> .env
    fi

    if grep -q '^NEXT_PUBLIC_APP_URL=' .env; then
        sed -i 's|^NEXT_PUBLIC_APP_URL=.*|NEXT_PUBLIC_APP_URL=http://localhost:3000|' .env
    else
        echo "NEXT_PUBLIC_APP_URL=http://localhost:3000" >> .env
    fi

    if ! grep -q '^SUPPORT_EMAIL=' .env; then
        echo "SUPPORT_EMAIL=support@example.com" >> .env
    fi
else
    echo "[INFO] .env уже существует, используем существующий файл."
fi

echo "[INFO] Сборка Docker-образов..."
docker compose build app migrate

echo "[INFO] Запуск PostgreSQL и Redis..."
docker compose up -d db redis

echo "[INFO] Ожидание PostgreSQL..."

i=0
while [ "$i" -lt 30 ]; do
    if docker compose exec -T db pg_isready \
        -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)" \
        -d "$(grep '^POSTGRES_DB=' .env | cut -d= -f2-)" \
        >/dev/null 2>&1; then
        echo "[OK] PostgreSQL готов."
        break
    fi

    i=$((i + 1))
    sleep 2
done

if [ "$i" -ge 30 ]; then
    echo "[FAIL] PostgreSQL не запустился." >&2
    exit 1
fi

echo "[INFO] Применение миграций..."
docker compose run --rm migrate

echo "[INFO] Загрузка тестовых данных..."

# Seed выполняем только если в БД ещё нет пользователей.
USER_COUNT=$(docker compose exec -T db \
    psql -U "$(grep '^POSTGRES_USER=' .env | cut -d= -f2-)" \
    -d "$(grep '^POSTGRES_DB=' .env | cut -d= -f2-)" \
    -tAc "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")

USER_COUNT=$(echo "$USER_COUNT" | tr -d '[:space:]')

if [ "$USER_COUNT" = "0" ]; then
    docker compose run --rm migrate \
        sh -c 'yarn workspace @rallly/database db:seed'
    echo "[OK] Тестовые данные загружены."
else
    echo "[INFO] Тестовые данные уже существуют, seed пропущен."
fi

echo "[INFO] Запуск Rallly..."
docker compose up -d app redis

echo "[INFO] Ожидание приложения..."

i=0
while [ "$i" -lt 60 ]; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:3000/ 2>/dev/null || echo "000")

    if [ "$CODE" = "200" ]; then
        echo "[OK] Rallly отвечает HTTP 200."
        break
    fi

    i=$((i + 1))
    sleep 2
done

if [ "$i" -ge 60 ]; then
    echo "[FAIL] Rallly не отвечает." >&2
    docker compose ps
    docker compose logs --no-color --tail=100 app
    exit 1
fi

echo ""
echo "=== Rallly успешно запущен ==="
echo "Приложение: http://localhost:3000"
echo "Логин:      http://localhost:3000/login"
echo ""

docker compose ps

exit 0
