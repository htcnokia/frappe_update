#!/bin/bash
# ==============================================================================
# Frappe/ERPNext 生产环境企业级自动更新脚本
# 集成：多环境 bench App.tag 源码热补丁 + 服务依赖自动修复
# ==============================================================================
# 使用前提：
# 1. 以 frappe 用户运行（绝不能 sudo ./此脚本）
# 2. 配置 sudoers 免密：
#    frappe ALL=(ALL) NOPASSWD: /usr/bin/supervisorctl, /bin/systemctl
# ==============================================================================

set -Eeuo pipefail
trap 'cleanup_on_failure $? $LINENO' ERR
trap 'remove_lock' EXIT

# ---- 配置 ----
BENCH_PATH="$HOME/frappe-bench"
LOCK_FILE="/tmp/bench_upgrade.lock"
LOG_DIR="$BENCH_PATH/logs/auto-update"
LOG_FILE="$LOG_DIR/update_$(date +%Y%m%d_%H%M%S).log"
MAINTENANCE_MODE_ACTIVE=0
SERVICES_STOPPED=0

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# ---- 1. 防止重复运行（互斥锁）----
if [ -e "$LOCK_FILE" ]; then
    log "[ERROR] 已有更新进程正在运行（锁文件: $LOCK_FILE），本次退出。"
    exit 1
fi
touch "$LOCK_FILE"

remove_lock() { rm -f "$LOCK_FILE"; }

# ---- 2. 异常捕获 & 应急回滚 ----
cleanup_on_failure() {
    local exit_code=$1
    local line_no=$2
    log "[FATAL] 脚本在第 $line_no 行异常退出（exit code: $exit_code）"

    if [ "$SERVICES_STOPPED" -eq 1 ]; then
        log "[RECOVERY] 尝试重启 Supervisor 服务..."
        sudo supervisorctl start all || log "[RECOVERY] 服务重启失败，请手动检查。"
    fi

    if [ "$MAINTENANCE_MODE_ACTIVE" -eq 1 ]; then
        log "[RECOVERY] 关闭维护模式..."
        cd "$BENCH_PATH" && bench --site all set-maintenance-mode off \
            || log "[RECOVERY] 维护模式关闭失败，请手动执行: bench --site all set-maintenance-mode off"
    fi

    log "[FATAL] 更新已中止，日志路径: $LOG_FILE"
    exit "$exit_code"
}

# ---- 3. 运行前检查 ----
if [ "$USER" = "root" ]; then
    log "[ERROR] 禁止以 root 用户运行本脚本，请切换为 frappe 用户。"
    exit 1
fi

cd "$BENCH_PATH" || { log "[ERROR] 无法进入 $BENCH_PATH"; exit 1; }

# ---- 4. 升级 bench 工具 ----
log "正在升级用户本地 bench 工具..."
python3 -m pip install --upgrade frappe-bench --break-system-packages \
    || log "[WARN] 用户本地 bench 升级失败，继续执行..."

BENCH_VER=$(bench --version 2>/dev/null || echo "unknown")
log "当前 bench 版本: $BENCH_VER"

# ---- 5. 多环境全路径穿透热补丁：修复 App.tag AttributeError ----
log "正在扫描并应用 bench App.tag 全路径源码热补丁..."

python3 << 'PYEOF'
import os
import sys
import glob
import re
import shutil
from datetime import datetime

PATCH_MARKER = "# PATCHED_TAG_ATTR"

search_patterns = [
    os.path.expanduser("~/.local/lib/python*/site-packages/bench/app.py"),
    "/usr/local/lib/python*/dist-packages/bench/app.py",
    "/usr/local/lib/python*/site-packages/bench/app.py",
    "/usr/lib/python*/dist-packages/bench/app.py",
    "/usr/lib/python*/site-packages/bench/app.py",
]

import subprocess
try:
    bench_bin = subprocess.check_output(["which", "-a", "bench"], text=True).strip().splitlines()
    for b in bench_bin:
        try:
            with open(b) as f:
                first_line = f.readline()
                if "python" in first_line:
                    py = first_line.strip().lstrip("#!")
                    candidate = os.path.join(
                        os.path.dirname(os.path.dirname(py)),
                        "lib", os.path.basename(os.path.dirname(py)),
                        "site-packages", "bench", "app.py"
                    )
                    search_patterns.append(candidate)
        except Exception:
            pass
except Exception:
    pass

all_paths = set()
for pattern in search_patterns:
    for p in glob.glob(pattern):
        all_paths.add(os.path.realpath(p))

if not all_paths:
    print("[热补丁] 未找到任何 bench/app.py，跳过。")
    sys.exit(0)

patched = 0
skipped = 0
for app_py in sorted(all_paths):
    try:
        with open(app_py, "r", encoding="utf-8") as f:
            content = f.read()

        if PATCH_MARKER in content:
            print(f"[热补丁] 已存在，跳过（幂等）: {app_py}")
            skipped += 1
            continue

        pyc_dir = os.path.join(os.path.dirname(app_py), "__pycache__")
        if os.path.isdir(pyc_dir):
            for pyc in glob.glob(os.path.join(pyc_dir, "app.cpython-*.pyc")):
                try:
                    os.remove(pyc)
                    print(f"[热补丁] 已清除旧字节码: {pyc}")
                except Exception:
                    pass

        backup = f"{app_py}.bak_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        shutil.copy2(app_py, backup)

        # 动态检测原文件的缩进风格（Tab 或 空格）
        indent = "\t" if "\tdef " in content else "    "

        patch_lines = [
            f"{indent}{PATCH_MARKER}: 防止 to_clone=False 路径下未初始化 tag 抛出 AttributeError",
            f"{indent}tag = property(",
            f"{indent}{indent}lambda self: getattr(self, '_tag', None),",
            f"{indent}{indent}lambda self, v: setattr(self, '_tag', v)",
            f"{indent})"
        ]
        patch_text = "\n" + "\n".join(patch_lines) + "\n"

        new_content = re.sub(
            r'(class App[^\n]*:\n)',
            r'\1' + patch_text,
            content,
            count=1
        )

        if new_content == content:
            print(f"[热补丁] 未找到 class App 定义，跳过: {app_py}")
            continue

        with open(app_py, "w", encoding="utf-8") as f:
            f.write(new_content)

        print(f"[热补丁] 成功注入: {app_py}")
        print(f"[热补丁] 原始备份: {backup}")
        patched += 1

    except PermissionError:
        print(f"[热补丁] 权限不足，跳过: {app_py}（可能需要 sudo）")
    except Exception as e:
        print(f"[热补丁] 处理失败: {app_py} -> {e}")

print(f"[热补丁] 完成：注入 {patched} 个文件，跳过 {skipped} 个。")
PYEOF

# ---- 6. 动态获取官方白名单 ----
log "从 GitHub API 获取 Frappe 官方仓库列表..."
OFFICIAL_APPS=()
GITHUB_API_OK=1

for page in 1 2 3; do
    result=$(curl -sf --connect-timeout 10 \
        "https://api.github.com/orgs/frappe/repos?per_page=100&page=${page}") \
        || { GITHUB_API_OK=0; break; }
    [ -z "$result" ] && break
    names=$(echo "$result" | python3 -c \
        "import sys,json; print('\n'.join(r['name'] for r in json.load(sys.stdin)))" \
        2>/dev/null) || { GITHUB_API_OK=0; break; }
    [ -z "$names" ] && break
    while IFS= read -r name; do
        [ -n "$name" ] && OFFICIAL_APPS+=("$name")
    done <<< "$names"
done

if [ "$GITHUB_API_OK" -eq 0 ] || [ "${#OFFICIAL_APPS[@]}" -eq 0 ]; then
    log "[WARN] GitHub API 不可用，启用离线静态白名单..."
    OFFICIAL_APPS=(
        "frappe" "erpnext" "hrms" "payments" "insights" "lms"
        "helpdesk" "crm" "builder" "wiki" "drive" "flow"
        "draw" "sheets" "telephony" "gameplan" "print_designer"
        "webshop" "lending" "education" "agriculture" "hospitality"
        "non_profit" "ecommerce_integrations"
    )
else
    log "已获取 ${#OFFICIAL_APPS[@]} 个官方仓库。"
fi

# ---- 7. 进入维护模式 ----
log "开启全站维护模式..."
bench --site all set-maintenance-mode on
MAINTENANCE_MODE_ACTIVE=1

# ---- 8. 更新前备份 ----
log "执行更新前完整备份（含文件）..."
bench --site all backup --with-files
log "备份完成。"

# ---- 9. 停止 Web/Worker 服务（确保保留 Redis 正常运行）----
log "准备服务状态：停止应用 worker/web，保持 Redis 启动..."
if command -v supervisorctl &>/dev/null; then
    # 优先停止 worker 和 node web 进程
    sudo supervisorctl stop *:frappe-bench-workers:* 2>/dev/null || true
    sudo supervisorctl stop *:frappe-bench-web:* 2>/dev/null || true
fi

# 强行确保 Redis 服务准备到位
sudo systemctl start redis-server 2>/dev/null || sudo systemctl start redis 2>/dev/null || true
if command -v supervisorctl &>/dev/null; then
    sudo supervisorctl start *:frappe-bench-redis:* 2>/dev/null || true
    sudo supervisorctl start frappe-bench-redis 2>/dev/null || true
fi
SERVICES_STOPPED=1

# ---- 10. 应用状态对齐 ----
log "扫描并对齐应用状态..."
APPS=$(cat sites/apps.txt)

# 显式初始化为空数组，防止 set -u 在无自建应用暂存时报 unbound variable 错误
declare -a STASHED_APPS=()

for app in $APPS; do
    APP_DIR="apps/$app"
    [ -d "$APP_DIR/.git" ] || continue

    IS_OFFICIAL=false
    for official in "${OFFICIAL_APPS[@]}"; do
        [[ "$app" == "$official" ]] && IS_OFFICIAL=true && break
    done

    if [ "$IS_OFFICIAL" = true ]; then
        log "[官方应用] 强制对齐: $app"
        git -C "$APP_DIR" merge --abort >/dev/null 2>&1 || true
        git -C "$APP_DIR" reset --hard HEAD
        git -C "$APP_DIR" clean -fd
    else
        if [[ -n $(git -C "$APP_DIR" status --porcelain) ]]; then
            log "[自建应用] 暂存本地修改: $app"
            git -C "$APP_DIR" stash -u
            STASHED_APPS+=("$app")
        else
            log "[自建应用] 状态干净: $app"
        fi
    fi
done

# ---- 10b. Tag 补齐 ----
log "检查并为无 Tag 应用补齐初始标签..."
for app_dir in apps/*/; do
    [ -d "$app_dir/.git" ] || continue
    if [ -z "$(git -C "$app_dir" tag)" ]; then
        app_name=$(basename "$app_dir")
        log "[$app_name] 没有 Tag，正在打初始标签 v0.0.1..."
        git -C "$app_dir" tag v0.0.1
    fi
done

# ---- 11. 执行核心更新 ----
log "执行 bench update --reset ..."
bench update --reset --no-backup

# ---- 12. 恢复自建应用修改 ----
if [ "${#STASHED_APPS[@]}" -gt 0 ]; then
    for app in "${STASHED_APPS[@]}"; do
        log "恢复自建应用暂存: $app"
        git -C "apps/$app" stash pop \
            || log "[WARN] $app 恢复暂存失败，可能存在代码冲突，请手动检查。"
    done
fi

# ---- 13. 数据库迁移（增加 Redis 存活二次确保）----
log "再次强行确保 Redis 运行，执行数据库迁移..."
sudo systemctl start redis-server 2>/dev/null || sudo systemctl start redis 2>/dev/null || true
if command -v supervisorctl &>/dev/null; then
    sudo supervisorctl start *:frappe-bench-redis:* 2>/dev/null || true
    sudo supervisorctl start frappe-bench-redis 2>/dev/null || true
fi

log "执行数据库迁移（Schema Migration）..."
bench migrate

# ---- 14. 重建翻译文件 ----
log "重建翻译模板..."
python3 apps/frappe/rebuild_po.py 2>/dev/null || log "[WARN] 翻译重建跳过。"

# ---- 15. 编译静态资源 ----
log "编译 JS/CSS 静态资源..."
bench build

# ---- 16. 清理缓存 ----
log "清理 Redis 缓存..."
bench clear-cache

# ---- 17. 重启所有生产服务 ----
log "重启 Supervisor 所有服务..."
sudo supervisorctl start all
SERVICES_STOPPED=0

# ---- 18. 关闭维护模式 ----
log "关闭维护模式，恢复对外访问..."
bench --site all set-maintenance-mode off
MAINTENANCE_MODE_ACTIVE=0

log "======================================================================"
log "SUCCESS: 生产环境更新全部完成。"
log "日志路径: $LOG_FILE"
log "======================================================================"
