#!/bin/sh
set -e

if ! command -v docker >/dev/null 2>&1; then
    echo "Ошибка: docker не установлен." >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Ошибка: git не установлен." >&2
    exit 1
fi

if [ ! -f .env ]; then
    echo "Создание .env файла..."
    cp .env.example .env
    PG_PASS=$(openssl rand -hex 16 2>/dev/null || echo "pass_$(date +%s)")
    SEC_PASS=$(openssl rand -hex 16 2>/dev/null || echo "sec_$(date +%s)")
    sed -i "s/POSTGRES_PASSWORD=/POSTGRES_PASSWORD=$PG_PASS/" .env
    sed -i "s/SECRET_PASSWORD=/SECRET_PASSWORD=$SEC_PASS/" .env
fi

echo "Сборка контейнеров..."
docker compose build

echo "Запуск сервисов..."
docker compose up -d

echo "Ожидание готовности сервисов..."
sleep 10

echo "Проверка доступности..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 || echo "000")

echo "=== Результат ==="
echo "HTTP код: $HTTP_CODE"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "[OK] Приложение запущено!"
    exit 0
else
    echo "[FAIL] Ошибка запуска"
    exit 1
fi
