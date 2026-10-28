#!/system/bin/sh
MODDIR=${0%/*}
[[ -f /data/adb/turbo-charge/log.txt ]] && mv -f /data/adb/turbo-charge/log.txt /data/adb/turbo-charge/log.txt.old
echo "等待手机启动完毕，以确保时间准确。若只看到这一行内容，请立即联系模块作者！" > /data/adb/turbo-charge/log.txt
until [[ "$(getprop service.bootanim.exit)" == "1" ]]; do
    sleep 1
done
echo "手机启动完毕" >> /data/adb/turbo-charge/log.txt
echo "" >> /data/adb/turbo-charge/log.txt
[[ -e /data/vendor/thermal ]] && chattr -i $(find /data/vendor/thermal)
rm -rf /data/vendor/thermal
mkdir -p /data/vendor/thermal/config
chattr +i /data/vendor/thermal/config /data/vendor/thermal
nohup ${MODDIR}/turbo-charge > /dev/null 2>&1 &
sleep 1
first_process=$(ps -eo comm,pid | grep "turbo-charge" | awk '{print $2}')
nohup ${MODDIR}/turbo-charge >> /data/adb/turbo-charge/log.txt 2>&1 &
sleep 60
[[ -n "${first_process}" ]] && kill ${first_process}

# ============================================================
# WebUI 控制面板 (Yxlan-yu 二改)
# 从 KernelSU / Magisk 管理器打开模块 WebUI 即可访问
# 安全策略：只监听 127.0.0.1，局域网内其它设备连不上
#   1) 首选 busybox nc -s 127.0.0.1 绑定回环地址
#   2) 若 nc 不支持 -s（或绑定失败），退回全局监听，并用 iptables
#      丢掉一切非 127.0.0.1 来源的 8080 访问（两条路都会加，双保险）
# 基于 busybox nc 的轻量 HTTP 服务，每连接启动一次 http_api.sh
# ============================================================
WEBUI_PORT=8080
WEBUI_BIND=127.0.0.1
WEBUI_API="${MODDIR}/http_api.sh"
TCP_DIR=/data/adb/turbo-charge
[ -d "$TCP_DIR" ] || mkdir -p "$TCP_DIR"
WEBUI_PIDFILE="$TCP_DIR/webui.pid"
WEBUI_LOG="$TCP_DIR/webui.log"
WEBUI_IPT_FILE="$TCP_DIR/webui.iptables"

log_webui() {
    echo "[$(date '+%F %T')] $*" >> "$WEBUI_LOG"
}

find_busybox() {
    if [ -x /data/adb/ksu/bin/busybox ]; then echo /data/adb/ksu/bin/busybox; return; fi
    if [ -x /data/adb/magisk/busybox ]; then echo /data/adb/magisk/busybox; return; fi
    if [ -x /data/adb/modules/ksu-busybox/busybox ]; then echo /data/adb/modules/ksu-busybox/busybox; return; fi
    if [ -x /system/xbin/busybox ]; then echo /system/xbin/busybox; return; fi
    if command -v busybox >/dev/null 2>&1; then echo busybox; return; fi
    echo ""
}
BUSYBOX=$(find_busybox)

find_iptables() {
    for CAND in /system/bin/iptables /system/xbin/iptables \
                /data/adb/ksu/bin/iptables /data/adb/magisk/iptables \
                /data/adb/modules/ksu-busybox/iptables; do
        if [ -x "$CAND" ]; then echo "$CAND"; return; fi
    done
    CAND=$(command -v iptables 2>/dev/null)
    if [ -n "$CAND" ]; then echo "$CAND"; return; fi
    echo ""
}
IPTABLES=$(find_iptables)

# 读 /proc/net/tcp 拿 8080 的实际监听地址，只用于写日志（便于排查）
webui_bind_state() {
    HEXPORT=$(printf '%04X' "$WEBUI_PORT")
    for F in /proc/net/tcp /proc/net/tcp6; do
        [ -f "$F" ] || continue
        $BUSYBOX awk -v p="$HEXPORT" 'NR > 1 && $4 == "0A" && substr($2, length($2) - 3) == p { print $2; exit }' "$F" 2>/dev/null
    done
}

# 兜底拦截：无论 nc 是否成功只绑回环，都拒绝非本机来源访问 8080
iptables_guard() {
    [ -n "$IPTABLES" ] || return 0
    if "$IPTABLES" -C INPUT -p tcp --dport "$WEBUI_PORT" ! -s 127.0.0.1 -j DROP >/dev/null 2>&1; then
        echo "$IPTABLES" > "$WEBUI_IPT_FILE"
        return 0
    fi
    if "$IPTABLES" -I INPUT -p tcp --dport "$WEBUI_PORT" ! -s 127.0.0.1 -j DROP >/dev/null 2>&1; then
        echo "$IPTABLES" > "$WEBUI_IPT_FILE"
        log_webui "iptables 兜底规则已生效：非 127.0.0.1 来源访问 $WEBUI_PORT 一律丢弃"
    else
        log_webui "警告：iptables 规则写入失败，端口安全仅依赖 nc 绑定地址"
    fi
}

# 清理可能残留的旧 instance（幂等：无条件重启 WebUI）
for OLD_PIDFILE in "$WEBUI_PIDFILE" "${MODDIR}/webui.pid"; do
    if [ -f "$OLD_PIDFILE" ]; then
        OLD_PID=$(cat "$OLD_PIDFILE" 2>/dev/null)
        if [ -n "$OLD_PID" ]; then
            kill -9 "$OLD_PID" 2>/dev/null
        fi
        rm -f "$OLD_PIDFILE"
    fi
done

# 额外按命令行清理本模块遗留 nc 进程，防止端口被占
PIDS=$($BUSYBOX ps -eo pid,args 2>/dev/null | $BUSYBOX grep "nc -lk" | $BUSYBOX grep " -p ${WEBUI_PORT}" | $BUSYBOX grep -v grep | $BUSYBOX awk '{print $1}')
if [ -n "$PIDS" ]; then
    echo "$PIDS" | while read -r P; do kill -9 "$P" 2>/dev/null; done
fi

# 等待系统完全就绪（boot_completed/sys.boot_completed 在 service 阶段已过）
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

start_webui() {
    # 首选：只监听回环地址，局域网内其它设备根本连不上
    nohup "$BUSYBOX" nc -lk -s "$WEBUI_BIND" -p "$WEBUI_PORT" -e /system/bin/sh "$WEBUI_API" "$MODDIR" "$WEBUI_PORT" >> "$WEBUI_LOG" 2>&1 &
    NEW_PID=$!
    sleep 1
    if kill -0 "$NEW_PID" 2>/dev/null; then
        echo "$NEW_PID" > "$WEBUI_PIDFILE"
        iptables_guard
        BIND_STATE=$(webui_bind_state)
        case "$BIND_STATE" in
            "") log_webui "WebUI 启动 (pid=$NEW_PID, port=$WEBUI_PORT, bind=$WEBUI_BIND, 监听状态未知)" ;;
            0100007F:*) log_webui "WebUI 启动 (pid=$NEW_PID, port=$WEBUI_PORT, 仅监听 127.0.0.1)" ;;
            00000000:*) log_webui "WebUI 启动 (pid=$NEW_PID, port=$WEBUI_PORT, 监听全部地址，已由 iptables 拦截外部访问)" ;;
            *) log_webui "WebUI 启动 (pid=$NEW_PID, port=$WEBUI_PORT, 监听 $BIND_STATE)" ;;
        esac
        return 0
    fi
    # 兜底：部分 busybox 的 nc 没有 -s，退回全局监听，由 iptables 拦截外部访问
    log_webui "nc -s $WEBUI_BIND 不可用，改用全局监听 + iptables 拦截"
    nohup "$BUSYBOX" nc -lk -p "$WEBUI_PORT" -e /system/bin/sh "$WEBUI_API" "$MODDIR" "$WEBUI_PORT" >> "$WEBUI_LOG" 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > "$WEBUI_PIDFILE"
    iptables_guard
    if [ -z "$IPTABLES" ]; then
        log_webui "警告：未找到 iptables，$WEBUI_PORT 端口可能对局域网可见"
    fi
    log_webui "WebUI 启动 (pid=$NEW_PID, port=$WEBUI_PORT, bind=0.0.0.0)"
}

# webui.log 超过 256KB 时只保留末尾 128KB，避免长期运行撑爆 /data
rotate_webui_log() {
    [ -f "$WEBUI_LOG" ] || return 0
    SZ=$($BUSYBOX wc -c < "$WEBUI_LOG" 2>/dev/null)
    case "$SZ" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$SZ" -gt 262144 ]; then
        $BUSYBOX tail -c 131072 "$WEBUI_LOG" > "${WEBUI_LOG}.tmp" 2>/dev/null &&
            mv -f "${WEBUI_LOG}.tmp" "$WEBUI_LOG"
    fi
}

if [ -x "$BUSYBOX" ] && [ -f "$WEBUI_API" ]; then
    start_webui
    # 看门狗：每 30s 巡检一次，进程掉了自动拉起（nc 偶发被系统杀掉时无需重启手机）
    (
        while true; do
            sleep 30
            rotate_webui_log
            PID=$(cat "$WEBUI_PIDFILE" 2>/dev/null)
            ALIVE=0
            if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
                CMD=$($BUSYBOX tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)
                case "$CMD" in
                    *nc*) ALIVE=1 ;;
                esac
            fi
            if [ "$ALIVE" = "0" ]; then
                log_webui "WebUI 进程不在，重新拉起"
                start_webui
            fi
        done
    ) >/dev/null 2>&1 &
else
    log_webui "未找到 busybox 或 http_api.sh，跳过 WebUI 启动"
fi

exit 0
