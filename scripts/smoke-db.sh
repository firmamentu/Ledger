#!/bin/bash
set -euo pipefail

# 数据库冒烟测试：验证 schema、user_version 与迁移幂等。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/Ledger.app/Contents/MacOS/Ledger"
DB="$HOME/Library/Application Support/com.ledger.app/ledger.sqlite"

"$ROOT/scripts/build-app.sh" >/dev/null

check_db() {
    local version tables integrity
    version=$(sqlite3 "$DB" 'PRAGMA user_version;')
    tables=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';")
    integrity=$(sqlite3 "$DB" 'PRAGMA integrity_check;')
    [[ "$version" == "1" ]]    || { echo "FAIL: user_version=$version"; exit 1; }
    [[ "$tables" == "7" ]]     || { echo "FAIL: tables=$tables"; exit 1; }
    [[ "$integrity" == "ok" ]] || { echo "FAIL: integrity=$integrity"; exit 1; }
}

start_app() {
    "$BIN" >/dev/null 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 100); do
        [[ -f "$DB" ]] && break
        sleep 0.1
    done
    [[ -f "$DB" ]] || { echo "FAIL: 未创建 ledger.sqlite"; exit 1; }
}

stop_app() {
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
}

# 先清掉可能正在运行的实例，避免锁冲突干扰测试
pkill -f '/Ledger.app/Contents/MacOS/Ledger' 2>/dev/null || true
sleep 0.5

start_app
check_db
stop_app

start_app   # 第二次启动：验证迁移幂等
check_db
stop_app

echo "smoke-db: OK"
