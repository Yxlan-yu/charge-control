#!/system/bin/sh
# =========================================================
#  充电调控 · 面板命令行接口 (v1.1)
#
#  给模块管理器的 ksu.exec 用：不监听任何端口、不创建任何 socket。
#  管理器（KernelSU / SukiSU / KernelSU-Next）把前端注入的 JS 桥接给
#  root shell，前端执行本脚本即可，外部 App 根本无端口可连。
#
#  用法:
#    api_cli.sh <路径?查询> <METHOD> [base64 请求体]
#  例:
#    api_cli.sh /api/ping GET
#    api_cli.sh '/api/log?n=200&src=cur' GET
#    api_cli.sh /api/config POST Y3ljbGVfdGltZT0xJkNVUlJFTlRfTUFYPTUwMDAwMDAw
#
#  输出 = http_api.sh 的原始 HTTP 响应（状态行 + 头 + 空行 + 正文），
#  由前端解析。本脚本只负责「把参数拼成一次请求」，路由与校验逻辑
#  完全复用 http_api.sh，行为与之前的 nc 直连逐字节一致。
# =========================================================

MODDIR="${0%/*}"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/charge-control"
API="$MODDIR/http_api.sh"

PATHQ="${1:-/api/ping}"
METHOD="${2:-GET}"
BODY64="${3:-}"

case "$METHOD" in
    GET|POST|PUT|OPTIONS) ;;
    *) METHOD=GET ;;
esac
case "$PATHQ" in
    /*) ;;
    *) PATHQ="/$PATHQ" ;;
esac

die() {
    # $1 = 纯 ASCII 错误信息
    printf 'HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' "${#1}" "$1"
    exit 0
}

[ -f "$API" ] || die '{"ok":false,"error":"http_api.sh not found"}'

find_busybox() {
    if [ -x /data/adb/ksu/bin/busybox ]; then echo /data/adb/ksu/bin/busybox; return; fi
    if [ -x /data/adb/magisk/busybox ]; then echo /data/adb/magisk/busybox; return; fi
    if [ -x /data/adb/ap/bin/busybox ]; then echo /data/adb/ap/bin/busybox; return; fi
    if [ -x /data/adb/modules/ksu-busybox/busybox ]; then echo /data/adb/modules/ksu-busybox/busybox; return; fi
    if [ -x /system/xbin/busybox ]; then echo /system/xbin/busybox; return; fi
    if command -v busybox >/dev/null 2>&1; then echo busybox; return; fi
    echo ""
}
BB=$(find_busybox)

# ---- base64 解码（表单正文只含 ASCII，base64 里也只有 ASCII，安全） ----
BODY=""
if [ -n "$BODY64" ]; then
    if [ -n "$BB" ]; then
        BODY=$(printf '%s' "$BODY64" | "$BB" base64 -d 2>/dev/null)
    fi
    if [ -z "$BODY" ]; then
        BODY=$(printf '%s' "$BODY64" | base64 -d 2>/dev/null)
    fi
    if [ -z "$BODY" ]; then
        BODY=$(printf '%s' "$BODY64" | toybox base64 -d 2>/dev/null)
    fi
fi

if [ -n "$BB" ]; then
    CLEN=$(printf '%s' "$BODY" | "$BB" wc -c 2>/dev/null)
    set -- $CLEN
    CLEN="${1:-0}"
else
    CLEN=${#BODY}
fi
case "$CLEN" in ''|*[!0-9]*) CLEN=0 ;; esac

# 拼一条最小的 HTTP/1.1 请求，直接喂给 http_api.sh（它从 stdin 读请求）
# 第二个参数传 0：表示不是端口模式，/api/ping 里的 port 字段为 0
printf '%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded; charset=utf-8\r\nContent-Length: %s\r\n\r\n%s' \
    "$METHOD" "$PATHQ" "$CLEN" "$BODY" | /system/bin/sh "$API" "$MODDIR" 0
