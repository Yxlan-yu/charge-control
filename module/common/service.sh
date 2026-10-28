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
# 从 KernelSU 打开模块 WebUI 或浏览器访问 http://手机IP:8080
# 基于 busybox nc 的轻量 HTTP 服务，每连接启动一次 http_api.sh
# ============================================================
WEBUI_PORT=8080
WEBUI_API="${MODDIR}/http_api.sh"
TCP_DIR=/data/adb/turbo-charge
[ -d "$TCP_DIR" ] || mkdir -p "$TCP_DIR"
WEBUI_PIDFILE="$TCP_DIR/webui.pid"
WEBUI_LOG="$TCP_DIR/webui.log"

find_busybox() {
    if [ -x /data/adb/ksu/bin/busybox ]; then echo /data/adb/ksu/bin/busybox; return; fi
    if [ -x /data/adb/magisk/busybox ]; then echo /data/adb/magisk/busybox; return; fi
    if [ -x /data/adb/modules/ksu-busybox/busybox ]; then echo /data/adb/modules/ksu-busybox/busybox; return; fi
    if [ -x /system/xbin/busybox ]; then echo /system/xbin/busybox; return; fi
    if command -v busybox >/dev/null 2>&1; then echo busybox; return; fi
    echo ""
}
BUSYBOX=$(find_busybox)

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
PIDS=$($BUSYBOX ps -eo pid,args 2>/dev/null | $BUSYBOX grep "busybox nc -lk -p ${WEBUI_PORT}" | $BUSYBOX grep -v grep | $BUSYBOX awk '{print $1}')
if [ -n "$PIDS" ]; then
    echo "$PIDS" | while read -r P; do kill -9 "$P" 2>/dev/null; done
fi

# 等待系统完全就绪（boot_completed/sys.boot_completed 在 service 阶段已过）
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

log_webui() {
    echo "[$(date '+%F %T')] $*" >> "$WEBUI_LOG"
}

start_webui() {
    nohup "$BUSYBOX" nc -lk -p "$WEBUI_PORT" -e /system/bin/sh "$WEBUI_API" "$MODDIR" "$WEBUI_PORT" >> "$WEBUI_LOG" 2>&1 &
    echo $! > "$WEBUI_PIDFILE"
    log_webui "WebUI 启动 (pid=$(cat "$WEBUI_PIDFILE" 2>/dev/null), port=$WEBUI_PORT)"
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