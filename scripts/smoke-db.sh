#!/bin/bash
set -euo pipefail

# 数据库冒烟测试：验证 schema、user_version、迁移幂等、应用存活与单实例。
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
    [[ "$tables" == "8" ]]     || { echo "FAIL: tables=$tables"; exit 1; }
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
    # 等应用完成启动（migrate 补建 index_entries 后）再校验，避免与启动竞争
    for _ in $(seq 1 100); do
        local n
        n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='index_entries';" 2>/dev/null || echo 0)
        [[ "$n" == "1" ]] && break
        sleep 0.1
    done
    kill -0 "$APP_PID" 2>/dev/null || { echo "FAIL: 应用启动后未存活"; exit 1; }
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

# 单实例回归：第二个实例必须在 5 秒内自行退出，且恰好存活 1 个
# 注意用 wait 收割退出状态；kill -0 对僵尸进程仍会成功，不能作为判定
start_app
# 等第一个实例真正拿到单实例锁（锁文件已打开）再启动第二个，避免抢锁竞态
for _ in $(seq 1 100); do
    lsof -p "$APP_PID" 2>/dev/null | grep -q ledger.lock && break
    sleep 0.1
done
"$BIN" >/dev/null 2>&1 &
SECOND=$!
( sleep 5; kill -9 "$SECOND" 2>/dev/null ) &
WATCHDOG=$!
if wait "$SECOND" 2>/dev/null; then
    STATUS=0
else
    STATUS=$?
fi
kill "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true
if [[ $STATUS != 0 ]]; then
    echo "FAIL: 第二个实例未在 5 秒内自行退出（status=$STATUS）"
    stop_app
    exit 1
fi
ALIVE=$(pgrep -x Ledger | wc -l | tr -d ' ')
[[ "$ALIVE" == "1" ]] || { echo "FAIL: 存活实例数=$ALIVE"; exit 1; }
stop_app

echo "smoke-db: OK"
