#!/bin/sh
set -e

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$ROOT_DIR/.rallly-source"
UPSTREAM_URL="https://github.com/lukevella/rallly.git"
UPSTREAM_TAG="v3.10.0"
UPSTREAM_COMMIT="eeccdbda94321185e2b32a1f05a7948a2e0b7d8d"

cd "$ROOT_DIR"

echo "=== Rallly setup ==="

for cmd in docker git openssl curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[FAIL] Не найдена команда: $cmd" >&2
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    echo "[FAIL] Docker Compose недоступен." >&2
    exit 1
fi

echo "[INFO] Получение официального исходного кода Rallly..."

if [ ! -d "$SOURCE_DIR/.git" ]; then
    if [ -e "$SOURCE_DIR" ]; then
        echo "[FAIL] $SOURCE_DIR существует, но не является Git-репозиторием." >&2
        exit 1
    fi
    git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$SOURCE_DIR"
else
    git -C "$SOURCE_DIR" fetch --depth 1 origin "refs/tags/$UPSTREAM_TAG"
fi

git -C "$SOURCE_DIR" checkout --detach "$UPSTREAM_COMMIT"

ACTUAL_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [ "$ACTUAL_COMMIT" != "$UPSTREAM_COMMIT" ]; then
    echo "[FAIL] Не совпадает закреплённый upstream-коммит." >&2
    exit 1
fi

echo "[OK] Используется upstream-коммит: $ACTUAL_COMMIT"

echo "[INFO] Копирование DevOps-конфигурации..."
cp "$ROOT_DIR/Dockerfile" "$SOURCE_DIR/Dockerfile"
cp "$ROOT_DIR/docker-compose.yml" "$SOURCE_DIR/docker-compose.yml"
cp "$ROOT_DIR/.env.example" "$SOURCE_DIR/.env.example"

dc() {
    docker compose -p devops-rallly \
        --project-directory "$SOURCE_DIR" \
        --env-file "$ROOT_DIR/.env" \
        -f "$SOURCE_DIR/docker-compose.yml" "$@"
}

if [ ! -f "$ROOT_DIR/.env" ]; then
    echo "[INFO] Создание .env..."
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"

    PG_PASS=$(openssl rand -hex 16)
    SEC_PASS=$(openssl rand -hex 16)
    AUTH_SECRET=$(openssl rand -hex 32)

    sed -i "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$PG_PASS/" "$ROOT_DIR/.env"
    sed -i "s/^SECRET_PASSWORD=$/SECRET_PASSWORD=$SEC_PASS/" "$ROOT_DIR/.env"

    if grep -q '^NEXTAUTH_SECRET=' "$ROOT_DIR/.env"; then
        sed -i "s|^NEXTAUTH_SECRET=.*|NEXTAUTH_SECRET=$AUTH_SECRET|" "$ROOT_DIR/.env"
    else
        echo "NEXTAUTH_SECRET=$AUTH_SECRET" >> "$ROOT_DIR/.env"
    fi

    if grep -q '^NEXTAUTH_URL=' "$ROOT_DIR/.env"; then
        sed -i 's|^NEXTAUTH_URL=.*|NEXTAUTH_URL=http://localhost:3000|' "$ROOT_DIR/.env"
    else
        echo "NEXTAUTH_URL=http://localhost:3000" >> "$ROOT_DIR/.env"
    fi

    if grep -q '^NEXT_PUBLIC_APP_URL=' "$ROOT_DIR/.env"; then
        sed -i 's|^NEXT_PUBLIC_APP_URL=.*|NEXT_PUBLIC_APP_URL=http://localhost:3000|' "$ROOT_DIR/.env"
    else
        echo "NEXT_PUBLIC_APP_URL=http://localhost:3000" >> "$ROOT_DIR/.env"
    fi

    if ! grep -q '^SUPPORT_EMAIL=' "$ROOT_DIR/.env"; then
        echo "SUPPORT_EMAIL=support@example.com" >> "$ROOT_DIR/.env"
    fi
else
    echo "[INFO] .env уже существует, используем существующий файл."
fi

echo "[INFO] Сборка Docker-образов..."
dc build app migrate

echo "[INFO] Запуск PostgreSQL и Redis..."
dc up -d db redis

echo "[INFO] Ожидание PostgreSQL..."
i=0
while [ "$i" -lt 30 ]; do
    if dc exec -T db pg_isready \
        -U "$(grep '^POSTGRES_USER=' "$ROOT_DIR/.env" | cut -d= -f2-)" \
        -d "$(grep '^POSTGRES_DB=' "$ROOT_DIR/.env" | cut -d= -f2-)" \
        >/dev/null 2>&1; then
        echo "[OK] PostgreSQL готов."
        break
    fi
    i=$((i + 1))
    sleep 2
done

if [ "$i" -ge 30 ]; then
    echo "[FAIL] PostgreSQL не запустился." >&2
    dc logs --tail=100 db
    exit 1
fi

echo "[INFO] Применение миграций..."
dc run --rm migrate

echo "[INFO] Проверка тестовых данных..."
USER_COUNT=$(dc exec -T db \
    psql -U "$(grep '^POSTGRES_USER=' "$ROOT_DIR/.env" | cut -d= -f2-)" \
    -d "$(grep '^POSTGRES_DB=' "$ROOT_DIR/.env" | cut -d= -f2-)" \
    -tAc "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
USER_COUNT=$(echo "$USER_COUNT" | tr -d '[:space:]')

if [ "$USER_COUNT" = "0" ]; then
    dc run --rm migrate sh -c 'yarn workspace @rallly/database db:seed'
    echo "[OK] Тестовые данные загружены."
else
    echo "[INFO] Пользователи уже существуют, seed пропущен."
fi

echo "[INFO] Запуск Rallly..."
dc up -d app redis

echo "[INFO] Ожидание приложения..."
i=0
while [ "$i" -lt 60 ]; do
    CODE=$(curl --connect-timeout 5 --max-time 10 -sS \
    -o /dev/null -w "%{http_code}" \
    http://localhost:3000/ 2>&1) || CODE="000"

    if [ "$CODE" = "200" ]; then
        echo "[OK] Rallly отвечает HTTP 200."
        break
    fi

    i=$((i + 1))
    sleep 2
done

if [ "$i" -ge 60 ]; then
    echo "[FAIL] Rallly не отвечает." >&2
    dc ps
    dc logs --no-color --tail=100 app
    exit 1
fi

echo ""
echo "=== Rallly успешно запущен ==="
echo "Приложение: http://localhost:3000"
echo "Логин:      http://localhost:3000/login"
dc ps
