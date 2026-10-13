#!/bin/sh
set -e

HOST="http://localhost:3000"
FAILED=0

check_endpoint() {
    PATH_REQ="$1"
    EXPECTED="$2"
    CODE=$(curl -L --connect-timeout 5 --max-time 20 -sS -o /dev/null -w "%{http_code}" "$HOST$PATH_REQ") || CODE="000"
    
    if [ "$CODE" = "$EXPECTED" ]; then
        echo "[OK] GET $PATH_REQ (got $CODE)"
    else
        echo "[FAIL] GET $PATH_REQ (expected $EXPECTED, got $CODE)"
        FAILED=1
    fi
}

check_endpoint "/" "200"
check_endpoint "/login" "200"
check_endpoint "/new" "200"

if [ "$FAILED" -eq 1 ]; then
    exit 1
fi
exit 0
