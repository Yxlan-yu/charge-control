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
# 旧版（v1.0 及更早）回环端口 WebUI 的遗留清理
# v1.1 起面板改走模块管理器的 ksu.exec 直连，模块不再监听任何端口，
# 这里把上一版留下的 iptables 规则 / nc 进程 / 状态文件清掉。
# 只做删除，不影响充电逻辑；没有遗留时整段空转。
# ============================================================
TCP_DIR=/data/adb/turbo-charge
LEGACY_IPT="$TCP_DIR/webui.iptables"
LEGACY_PIDFILE="$TCP_DIR/webui.pid"

if [ -f "$LEGACY_IPT" ]; then
    LEGACY_IPT_BIN=$(cat "$LEGACY_IPT" 2>/dev/null)
    if [ -n "$LEGACY_IPT_BIN" ] && [ -x "$LEGACY_IPT_BIN" ]; then
        "$LEGACY_IPT_BIN" -D INPUT -p tcp --dport 8080 ! -s 127.0.0.1 -j DROP >/dev/null 2>&1
    fi
    rm -f "$LEGACY_IPT"
fi

if [ -f "$LEGACY_PIDFILE" ]; then
    LEGACY_PID=$(cat "$LEGACY_PIDFILE" 2>/dev/null)
    case "$LEGACY_PID" in
        ''|*[!0-9]*) : ;;
        *)
            # 校验命令行里确实是 nc，避免 PID 复用误杀
            LEGACY_CMD=$(tr '\0' ' ' < "/proc/$LEGACY_PID/cmdline" 2>/dev/null)
            case "$LEGACY_CMD" in
                *nc*) kill -9 "$LEGACY_PID" 2>/dev/null ;;
            esac
            ;;
    esac
    rm -f "$LEGACY_PIDFILE"
fi

exit 0
