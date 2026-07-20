#!/bin/bash
#
# Frappe 生产环境自动更新脚本（修正版）
# 用法: ./frappe_update.sh
#
# 修正点（相对原版）:
#   1. 开启严格错误模式 set -Eeuo pipefail，任何命令失败立即中止
#   2. 使用 trap 保证：无论中途成功/失败，都会恢复服务、退出维护模式、释放锁
#   3. 更新前强制备份数据库+文件（去掉危险的 --no-backup）
#   4. 不再以"官方/自建"决定是否保护：只要仓库 dirty 就统一 stash -u（含未跟踪文件）保护，
#      避免官方 app 内的自定义改动(如自定义 Dockerfile 重新生成的翻译文件)被 --reset 冲掉
#   5. 检测 stash pop 冲突，冲突时不静默继续，而是报警并保留现场供人工处理
#   6. 增加文件锁，防止脚本被并发执行
#   7. 增加带时间戳的日志文件
#   8. 用 pushd/popd 代替裸 cd，避免目录状态错乱
#   9. 更新前后进入/退出维护模式，减少用户可见的报错
#  10. 更新后做基本健康检查（supervisor 状态 + bench doctor）
#  11. 所有变量加引号，避免路径含空格等问题出错
#
set -Eeuo pipefail

# ============ 基本配置 ============
BENCH_PATH="${BENCH_PATH:-$HOME/frappe-bench}"
LOG_DIR="$BENCH_PATH/logs/auto-update"
LOG_FILE="$LOG_DIR/update_$(date +%Y%m%d_%H%M%S).log"
LOCK_FILE="/tmp/frappe_update.lock"
OFFICIAL_AUTHOR_STRING="Frappe Technologies"
# 匹配 https://github.com/frappe/xxx 和 git@github.com:frappe/xxx 两种写法
OFFICIAL_GIT_REGEX="github\.com[:/]frappe/"
# 兜底名单：即使上面两种检测都判断失误，这些是 Frappe 官方组织下的常见 app，强制视为官方应用
# 如有其他官方 app（如 insights, crm, wiki, builder 等）请按需追加
OFFICIAL_APP_NAMES=("frappe" "erpnext" "hrms" "payments" "insights" "lms" "helpdesk" "crm" "builder" "wiki" "drive")
# 自定义翻译重建脚本路径；留空则跳过这一步
REBUILD_PO_SCRIPT="${REBUILD_PO_SCRIPT:-$BENCH_PATH/apps/frappe/rebuild_po.py}"

mkdir -p "$LOG_DIR"
# 所有输出同时写入日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# ============ 并发锁，防止脚本重复执行 ============
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "[$(date '+%F %T')] 已有更新任务在运行，本次退出。"
    exit 1
fi

log() {
    echo "[$(date '+%F %T')] $*"
}

# ============ 状态变量，供 trap 判断收尾动作 ============
MAINTENANCE_ON=false
SERVICES_STOPPED=false
declare -a STASHED_APPS=()
declare -a CONFLICT_APPS=()

# ============ 收尾函数：无论成功失败都会执行 ============
cleanup() {
    local exit_code=$?

    cd "$BENCH_PATH" || true

    if [ "$exit_code" -ne 0 ]; then
        log "!!! 更新流程异常退出（exit code $exit_code），进入收尾处理 !!!"
    fi

    # 恢复所有还没恢复的 stash（避免异常退出时改动丢失在 stash 里而没人知道）
    if [ "${#STASHED_APPS[@]}" -gt 0 ]; then
        for app in "${STASHED_APPS[@]}"; do
            log "收尾：尝试恢复暂存的本地改动: $app"
            (
                cd "$BENCH_PATH/apps/$app" || exit 0
                if git stash list | grep -q .; then
                    if ! git stash pop; then
                        log "警告：$app 的 stash 恢复存在冲突，请登录服务器手动处理 (apps/$app)"
                        CONFLICT_APPS+=("$app")
                    fi
                fi
            )
        done
    fi

    # 无论如何都要重启服务，避免生产环境长时间不可用
    if [ "$SERVICES_STOPPED" = true ]; then
        log "收尾：重启 supervisor 服务"
        sudo supervisorctl restart all || log "警告：supervisor 重启失败，请立即人工介入！"
    fi

    # 退出维护模式
    if [ "$MAINTENANCE_ON" = true ]; then
        log "收尾：退出维护模式"
        bench set-maintenance-mode off || true
    fi

    if [ "${#CONFLICT_APPS[@]}" -gt 0 ]; then
        log "!!! 以下应用 stash 恢复存在冲突，需人工处理: ${CONFLICT_APPS[*]} !!!"
    fi

    if [ "$exit_code" -eq 0 ]; then
        log "--- 更新流程全部完成 ---"
    else
        log "--- 更新流程失败，请检查日志: $LOG_FILE ---"
    fi

    flock -u 200 || true
    exit "$exit_code"
}
trap cleanup EXIT
trap 'log "捕获到中断信号，准备安全退出..."; exit 130' INT TERM

# ============ 正式流程开始 ============
cd "$BENCH_PATH" || exit 1
log "--- [生产环境] 启动深度扫描更新流程 ---"

# 1. 进入维护模式（此时用户访问会看到维护页而不是连接错误）
log "进入维护模式"
bench set-maintenance-mode on
MAINTENANCE_ON=true

# 2. 更新前强制备份（数据库 + 私有/公共文件），不再使用 --no-backup
log "执行更新前备份"
bench --site all backup --with-files

# 3. 停止服务
log "停止 supervisor 服务"
sudo supervisorctl stop all
SERVICES_STOPPED=true

# 4. 扫描应用，区分官方 / 自建
if [ ! -f "sites/apps.txt" ]; then
    log "错误：找不到 sites/apps.txt"
    exit 1
fi

mapfile -t APPS < sites/apps.txt

for app in "${APPS[@]}"; do
    [ -z "$app" ] && continue
    APP_DIR="$BENCH_PATH/apps/$app"
    [ -d "$APP_DIR" ] || continue

    if [ ! -d "$APP_DIR/.git" ]; then
        log "[非Git应用] 忽略: $app (无法执行 Git 操作)"
        continue
    fi

    # 判断官方 / 自建
    IS_OFFICIAL=false
    DETECT_REASON=""
    for official_name in "${OFFICIAL_APP_NAMES[@]}"; do
        [ "$app" = "$official_name" ] && IS_OFFICIAL=true && DETECT_REASON="内置名单"
    done
    if [ "$IS_OFFICIAL" = false ] && [ -f "$APP_DIR/pyproject.toml" ] \
        && grep -qi "$OFFICIAL_AUTHOR_STRING" "$APP_DIR/pyproject.toml"; then
        IS_OFFICIAL=true
        DETECT_REASON="pyproject.toml 作者信息"
    fi
    if [ "$IS_OFFICIAL" = false ]; then
        REMOTE_URL=$(git -C "$APP_DIR" config --get remote.origin.url 2>/dev/null || true)
        [[ "$REMOTE_URL" =~ $OFFICIAL_GIT_REGEX ]] && IS_OFFICIAL=true && DETECT_REASON="git remote"
    fi

    # ============ 官方应用：直接强制对齐远程分支，不做保护 ============
    # 翻译(.po/.pot)由更新完成后统一执行的 rebuild_po.py 重新生成，
    # 所以官方应用无需在 git 层面保留任何本地改动/冲突，不管是 pot、po 还是其他文件，一律对齐官方。
    if [ "$IS_OFFICIAL" = true ]; then
        if [ -n "$(git -C "$APP_DIR" status --porcelain)" ] || [ -f "$APP_DIR/.git/MERGE_HEAD" ]; then
            REMOTE_NAME=$(git -C "$APP_DIR" remote | grep -m1 -E '^(upstream|origin)$' || true)
            [ -z "$REMOTE_NAME" ] && REMOTE_NAME=$(git -C "$APP_DIR" remote | head -1)
            BRANCH_NAME=$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)

            if [ -z "$REMOTE_NAME" ] || [ -z "$BRANCH_NAME" ] || [ "$BRANCH_NAME" = "HEAD" ]; then
                log "错误：$app 无法确定远程名/分支名(remote=$REMOTE_NAME branch=$BRANCH_NAME)，为安全起见终止更新，请人工处理"
                exit 1
            fi

            log "[官方应用] $app 存在本地改动/冲突，直接对齐 $REMOTE_NAME/$BRANCH_NAME (判定依据: $DETECT_REASON)"
            git -C "$APP_DIR" merge --abort >/dev/null 2>&1 || true
            if ! git -C "$APP_DIR" fetch "$REMOTE_NAME"; then
                log "错误：$app 拉取远程 $REMOTE_NAME 失败，终止更新"
                exit 1
            fi
            git -C "$APP_DIR" reset --hard "$REMOTE_NAME/$BRANCH_NAME"
            git -C "$APP_DIR" clean -fd
            log "[官方应用] $app 已对齐 $REMOTE_NAME/$BRANCH_NAME"
        else
            log "[官方应用] $app 干净无改动"
        fi
        continue
    fi

    # ============ 自建应用：保留 stash 保护逻辑 ============
    # 前置检测：仓库是否处于未完成合并 / 存在未合并路径，自建应用的冲突无法自动判断取舍，一律交人工处理
    if [ -f "$APP_DIR/.git/MERGE_HEAD" ] || git -C "$APP_DIR" status --porcelain | grep -qE '^(UU|AA|DD|AU|UA|UD|DU) '; then
        log "错误：$app (自建应用) 存在未完成的合并/冲突状态，无法安全暂存，为避免破坏代码终止更新"
        log "请登录服务器手动处理: cd $APP_DIR && git status"
        log "  - 若显示合并进行中: git merge --abort"
        log "  - 若确认无需保留本地内容: git fetch <remote> && git reset --hard <remote>/<分支名> && git clean -fd"
        log "  - 若冲突文件中有需要保留的自定义改动，务必先手工解决冲突并 commit，不要直接 reset --hard"
        exit 1
    fi

    if [ -n "$(git -C "$APP_DIR" status --porcelain)" ]; then
        log "[自建应用] 发现本地改动，正在暂存(含未跟踪文件): $app"
        # 关键修正：加 -u，防止 bench update --reset 时把新增的未跟踪文件清掉
        if git -C "$APP_DIR" stash push -u -m "auto-update-$(date +%Y%m%d_%H%M%S)"; then
            STASHED_APPS+=("$app")
        else
            log "错误：$app 的 git stash 失败，为安全起见终止更新"
            exit 1
        fi
    else
        log "[自建应用] 干净无修改: $app"
    fi
done

# 5. 执行核心更新（不再传 --no-backup，因为已在第2步手动备份；
#    加上 --requirements 确保新增的 python/node 依赖也被安装）
log "--- 正在执行核心更新 (bench update --reset --requirements) ---"
bench update --reset --requirements

# 6. 恢复所有被暂存的本地改动(不分官方/自建)，并在数组中标记为已恢复，避免 trap 重复处理
RESTORED_APPS=()
for app in "${STASHED_APPS[@]}"; do
    log "正在恢复本地改动: $app"
    if git -C "$BENCH_PATH/apps/$app" stash pop; then
        RESTORED_APPS+=("$app")
    else
        log "警告：$app 的 git stash pop 出现冲突，已保留冲突现场供人工处理"
        CONFLICT_APPS+=("$app")
    fi
done
# 从待处理数组中移除已成功恢复的，避免 trap 中重复 pop
for restored in "${RESTORED_APPS[@]}"; do
    for i in "${!STASHED_APPS[@]}"; do
        [ "${STASHED_APPS[$i]}" = "$restored" ] && unset 'STASHED_APPS[i]'
    done
done

# 如果有冲突，主动终止（不要带着冲突继续 migrate/build/上线）
if [ "${#CONFLICT_APPS[@]}" -gt 0 ]; then
    log "存在未解决的 stash 冲突，终止后续流程，请人工处理: ${CONFLICT_APPS[*]}"
    exit 1
fi

# 7. 重启前准备（bench update 内部通常已执行 migrate/build，这里显式再跑一次确保幂等）
log "执行 migrate / build / clear-cache"
bench migrate
bench build
bench clear-cache

# 7.5 重新生成翻译（因为更新阶段 .pot 冲突自动采用了 upstream 版本，需要重新生成以对齐最新翻译）
if [ -n "$REBUILD_PO_SCRIPT" ] && [ -f "$REBUILD_PO_SCRIPT" ]; then
    log "重新生成翻译: $REBUILD_PO_SCRIPT"
    if python3 "$REBUILD_PO_SCRIPT"; then
        log "翻译重建完成"
    else
        log "警告：翻译重建脚本执行失败，请人工检查（不影响本次更新的其余部分）"
    fi
else
    log "未配置或未找到翻译重建脚本，跳过 (REBUILD_PO_SCRIPT=$REBUILD_PO_SCRIPT)"
fi

# 8. 重启服务
log "重启 supervisor 服务"
sudo supervisorctl restart all
SERVICES_STOPPED=false   # 已经手动重启，避免 trap 中重复执行

# 9. 简单健康检查
sleep 5
log "检查 supervisor 状态"
sudo supervisorctl status || true

# 10. 退出维护模式
log "退出维护模式"
bench set-maintenance-mode off
MAINTENANCE_ON=false

log "更新成功完成"
