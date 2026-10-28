#!/system/bin/sh
# 卸载清理：先停掉 WebUI 的 nc 进程并撤掉 iptables 兜底规则，再删配置目录
IPT_FILE=/data/adb/turbo-charge/webui.iptables
if [ -f "$IPT_FILE" ]; then
    IPT=$(cat "$IPT_FILE" 2>/dev/null)
    if [ -n "$IPT" ] && [ -x "$IPT" ]; then
        N=0
        while [ "$N" -lt 5 ]; do
            "$IPT" -D INPUT -p tcp --dport 8080 ! -s 127.0.0.1 -j DROP >/dev/null 2>&1 || break
            N=$((N + 1))
        done
    fi
fi
PIDFILE=/data/adb/turbo-charge/webui.pid
if [ -f "$PIDFILE" ]; then
    W_PID=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$W_PID" ] && kill -9 "$W_PID" 2>/dev/null
fi
for P in $(ps -eo pid,args 2>/dev/null | grep "nc -lk" | grep " -p 8080" | grep -v grep | awk '{print $1}'); do
    kill -9 "$P" 2>/dev/null
done
[[ -e /data/vendor/thermal ]] && chattr -i $(find /data/vendor/thermal)
rm -rf /data/vendor/thermal /data/adb/turbo-charge
mkdir -p /data/vendor/thermal/config
