#!/system/bin/sh
# =========================================================
#  充电调控 WebUI · HTTP API  (v1.1)
#  用法: http_api.sh <MODDIR> <PORT>
#  两种调用方式（路由与校验逻辑完全相同）:
#    ① 零端口（v1.1 起默认）: 由 api_cli.sh 从 stdin 喂入一条 HTTP 请求，
#       PORT 固定传 0（/api/ping 的 port 字段即为 0）
#    ② 回环端口（v1.0 旧方式，仍可直接手跑）: 由 busybox nc -lk -e 为每个
#       连接调用一次，PORT 为实际监听端口
#
#  路由:
#    GET  /                     面板 (webroot/index.html)
#    GET  /panel.html           同上（兼容旧书签）
#    GET  /api/ping             健康检查
#    GET  /api/info             模块/设备/功能可用性
#    GET  /api/status           实时充电状态 + 生效策略
#    GET  /api/config           配置项 + 默认值
#    POST /api/config           保存配置（form: K=V&K2=V2）
#    POST /api/config/reset     src=bak 回滚备份 / src=default 恢复默认
#    GET  /api/bypass           旁路供电包名列表
#    POST /api/bypass           保存包名列表（form: text=...）
#    GET  /api/log              ?n=200&src=cur|old
#    POST /api/log/clear        清空当前日志
# =========================================================

MODDIR="${1:-${0%/*}}"
PORT="${2:-8080}"

TCP_DIR=/data/adb/turbo-charge
OPT_FILE="$TCP_DIR/option.txt"
OPT_BAK="$TCP_DIR/option.txt.bak"
OPT_DEF="$TCP_DIR/option.txt.default"
BYPASS_FILE="$TCP_DIR/bypass_charge.txt"
TC_LOG="$TCP_DIR/log.txt"
TC_LOG_OLD="$TCP_DIR/log.txt.old"
WEBROOT="$MODDIR/webroot/index.html"
MODPROP="$MODDIR/module.prop"
CR=$(printf '\r')

# ---- busybox 探测 (KernelSU / KernelSU-Next / Magisk / APatch / 系统) ----
find_busybox() {
    if [ -x /data/adb/ksu/bin/busybox ]; then echo /data/adb/ksu/bin/busybox; return; fi
    if [ -x /data/adb/magisk/busybox ]; then echo /data/adb/magisk/busybox; return; fi
    if [ -x /data/adb/ap/bin/busybox ]; then echo /data/adb/ap/bin/busybox; return; fi
    if [ -x /data/adb/modules/ksu-busybox/busybox ]; then echo /data/adb/modules/ksu-busybox/busybox; return; fi
    if [ -x /system/xbin/busybox ]; then echo /system/xbin/busybox; return; fi
    if command -v busybox >/dev/null 2>&1; then echo busybox; return; fi
    echo ""
}
BUSYBOX=$(find_busybox)
if [ -z "$BUSYBOX" ]; then
    printf 'HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: 16\r\n\r\nbusybox not found'
    exit 1
fi

# ---------- HTTP 基础 ----------

http_head() {
    # $1=status line  $2=ctype  $3=length
    printf 'HTTP/1.1 %s\r\n' "$1"
    printf 'Content-Type: %s\r\n' "$2"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n'
    printf 'Access-Control-Allow-Headers: Content-Type, X-Requested-With\r\n'
    printf 'Access-Control-Max-Age: 86400\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: %s\r\n' "$3"
    printf '\r\n'
}

http_send() {
    # $1=content  $2=ctype
    CTYPE="${2:-application/json; charset=utf-8}"
    LEN=$(printf '%s' "$1" | "$BUSYBOX" wc -c)
    LEN=$(echo $LEN)
    http_head "200 OK" "$CTYPE" "$LEN"
    printf '%s' "$1"
}

http_err() {
    # $1=code  $2=reason  $3=message
    MSG="${3:-$2}"
    BODY="{\"ok\":false,\"error\":\"$MSG\"}"
    LEN=$(printf '%s' "$BODY" | "$BUSYBOX" wc -c)
    LEN=$(echo $LEN)
    http_head "$1 $2" "application/json; charset=utf-8" "$LEN"
    printf '%s' "$BODY"
}

serve_file() {
    # $1=path  $2=ctype
    if [ ! -f "$1" ]; then
        http_err 404 "Not Found" "文件不存在"
        return
    fi
    LEN=$("$BUSYBOX" wc -c < "$1")
    LEN=$(echo $LEN)
    http_head "200 OK" "${2:-text/html; charset=utf-8}" "$LEN"
    "$BUSYBOX" cat "$1"
}

# ---------- 业务 ----------

api_ping() {
    VER=$(sed -n 's/^version=//p' "$MODPROP" 2>/dev/null | head -1)
    [ -z "$VER" ] && VER="unknown"
    http_send "{\"ok\":true,\"ver\":\"$VER\",\"port\":$PORT}"
}

api_info() {
    VER=$(sed -n 's/^version=//p' "$MODPROP" 2>/dev/null | head -1)
    [ -z "$VER" ] && VER="unknown"
    MODEL=$(getprop ro.product.model 2>/dev/null)
    [ -z "$MODEL" ] && MODEL="Android"
    DEVICE=$(getprop ro.product.device 2>/dev/null)
    REL=$(getprop ro.build.version.release 2>/dev/null)
    KREL=$(uname -r 2>/dev/null)

    CUR_FILE=""
    for f in /sys/class/power_supply/*/constant_charge_current_max \
             /sys/class/power_supply/*/fast_charge_current \
             /sys/class/power_supply/*/thermal_input_current; do
        if [ -f "$f" ]; then CUR_FILE="$f"; break; fi
    done

    SUSPEND_FILE=""
    for f in /sys/class/power_supply/battery/charging_enabled \
             /sys/class/power_supply/battery/battery_charging_enabled \
             /sys/class/power_supply/battery/input_suspend \
             /sys/class/qcom-battery/restricted_charging; do
        if [ -f "$f" ]; then SUSPEND_FILE="$f"; break; fi
    done

    f_yn() { if [ -f "$1" ]; then printf true; else printf false; fi; }

    F_STATUS=$(f_yn /sys/class/power_supply/battery/status)
    F_CAP=$(f_yn /sys/class/power_supply/battery/capacity)
    F_TEMP=$(f_yn /sys/class/power_supply/battery/temp)
    F_CUR=false; [ -n "$CUR_FILE" ] && F_CUR=true
    F_STEP=$(f_yn /sys/class/power_supply/battery/step_charging_enabled)
    F_SUSP=false; [ -n "$SUSPEND_FILE" ] && F_SUSP=true
    F_BYPASS=$(f_yn "$BYPASS_FILE")

    http_send "{\"ok\":true,\"module\":{\"version\":\"$VER\",\"dir\":\"$MODDIR\",\"installed\":$([ -d "$TCP_DIR" ] && printf true || printf false)},\"device\":{\"model\":\"$MODEL\",\"device\":\"$DEVICE\",\"android\":\"$REL\",\"kernel\":\"$KREL\"},\"env\":{\"busybox\":\"$BUSYBOX\",\"port\":$PORT,\"cur_file\":\"$CUR_FILE\",\"suspend_file\":\"$SUSPEND_FILE\"},\"feature\":{\"status\":$F_STATUS,\"capacity\":$F_CAP,\"temp\":$F_TEMP,\"current\":$F_CUR,\"step\":$F_STEP,\"suspend\":$F_SUSP,\"bypass\":$F_BYPASS}}"
}

api_status() {
    TS=$(date +%s 2>/dev/null)
    [ -z "$TS" ] && TS=0
    TCP_PID=$("$BUSYBOX" pidof turbo-charge 2>/dev/null)
    TCP_PID=$(echo $TCP_PID)

    "$BUSYBOX" awk -v TS="$TS" -v PORT="$PORT" -v OPT="$OPT_FILE" -v MODPROP="$MODPROP" -v PID="$TCP_PID" '
    function rd(f,   l) {
        if ((getline l < f) > 0) {
            sub(/\r$/, "", l)
            sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
            return l
        }
        return ""
    }
    function num(s, d) { return (s ~ /^-?[0-9]+$/) ? s + 0 : d }
    function esc(s) {
        sub(/\r$/, "", s)
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
        gsub(/[[:cntrl:]]/, "", s)
        return s
    }
    function pv(f, k,   l) {
        while ((getline l < f) > 0) {
            if (index(l, k "=") == 1) { sub(/\r$/, "", l); return substr(l, length(k) + 2) }
        }
        return ""
    }
    function absv(x) { return x < 0 ? -x : x }
    BEGIN {
        B = "/sys/class/power_supply/battery/"
        U = "/sys/class/power_supply/usb/"
        Q = "/sys/class/power_supply/bq2597x-standalone/"

        st = esc(rd(B "status"));      if (st == "") st = "unknown"
        cap = num(rd(B "capacity"), -1)
        tmp = num(rd(B "temp"), 0)
        bv = num(rd(B "voltage_now"), 0)
        bc = num(rd(B "current_now"), 0)
        chg = esc(rd(B "charge_type")); if (chg == "") chg = "unknown"
        hl = esc(rd(B "health"));       if (hl == "") hl = "unknown"

        uv = num(rd(U "voltage_now"), 0)
        uc = num(rd(U "input_current_now"), 0)
        ut = esc(rd(U "type")); if (ut == "") ut = "unknown"
        uon = rd(U "online")
        updv = num(rd(U "pd_voltage_max"), 0)
        updc = num(rd(U "pd_current_max"), 0)
        upm = num(rd(U "power_max"), 0)

        qe = esc(rd(Q "charging_enabled")); if (qe == "") qe = "none"
        qv = num(rd(Q "ti_bus_voltage"), 0)
        qc = num(rd(Q "ti_bus_current"), 0)
        qb = num(rd(Q "ti_battery_current"), 0)

        up = 0
        if ((getline up < "/proc/uptime") > 0) { split(up, _u, " "); up = int(_u[1]) }
        else up = 0

        pw = (bv / 1000000.0) * (absv(bc) / 1000000.0)
        upw = (uv / 1000000.0) * (absv(uc) / 1000000.0)

        ver = esc(pv(MODPROP, "version")); if (ver == "") ver = "unknown"

        cyc = num(pv(OPT, "CYCLE_TIME"), 1)
        ftm = num(pv(OPT, "FORCE_TEMP"), 0)
        tct = num(pv(OPT, "TEMP_CTRL"), 0)
        pct = num(pv(OPT, "POWER_CTRL"), 0)
        byp = num(pv(OPT, "BYPASS_CHARGE"), 0)
        cmax = num(pv(OPT, "CURRENT_MAX"), 0)
        tmax = num(pv(OPT, "TEMP_MAX"), 0)
        hcur = num(pv(OPT, "HIGHEST_TEMP_CURRENT"), 0)
        cstop = num(pv(OPT, "CHARGE_STOP"), 0)
        cstart = num(pv(OPT, "CHARGE_START"), 0)
        sdis = num(pv(OPT, "STEP_CHARGING_DISABLED"), 0)
        sthr = num(pv(OPT, "STEP_CHARGING_DISABLED_THRESHOLD"), 0)
        rt = num(pv(OPT, "RECHARGE_TEMP"), 0)

        onl = (uon == "1") ? "true" : "false"
        run = (PID != "") ? "true" : "false"

        batt = sprintf("{\"status\":\"%s\",\"capacity\":%d,\"temp\":%d,\"voltage\":%d,\"current\":%d,\"powerW\":%.2f,\"charge_type\":\"%s\",\"health\":\"%s\"}", st, cap, tmp, bv, bc, pw, chg, hl)
        usb  = sprintf("{\"type\":\"%s\",\"online\":%s,\"voltage\":%d,\"input_current\":%d,\"powerW\":%.2f,\"pd_voltage_max\":%d,\"pd_current_max\":%d,\"power_max\":%d}", ut, onl, uv, uc, upw, updv, updc, upm)
        bq   = sprintf("{\"charging_enabled\":\"%s\",\"bus_voltage\":%d,\"bus_current\":%d,\"battery_current\":%d}", qe, qv, qc, qb)
        pol  = sprintf("{\"cycle\":%d,\"forceTemp\":%d,\"tempCtrl\":%d,\"powerCtrl\":%d,\"bypass\":%d,\"currentMax\":%d,\"tempMax\":%d,\"highestTempCurrent\":%d,\"chargeStop\":%d,\"chargeStart\":%d,\"stepDisabled\":%d,\"stepThreshold\":%d,\"rechargeTemp\":%d}", cyc, ftm, tct, pct, byp, cmax, tmax, hcur, cstop, cstart, sdis, sthr, rt)
        mod  = sprintf("{\"installed\":%s,\"running\":%s,\"pid\":\"%s\",\"version\":\"%s\"}", (OPT ~ /./ ? "true" : "false"), run, PID, ver)

        printf "{\"ts\":%d,\"port\":%d,\"uptime\":%d,\"battery\":%s,\"usb\":%s,\"bq\":%s,\"policy\":%s,\"module\":%s}", TS, PORT, up, batt, usb, bq, pol, mod
    }' /dev/null
}

api_config_get() {
    if [ ! -f "$OPT_FILE" ]; then
        printf '%s' '{"ok":true,"exists":false,"config":{},"defaults":{}}'
        return
    fi
    "$BUSYBOX" awk -v OPT="$OPT_FILE" -v DEF="$OPT_DEF" '
    function rd(f, k,   l) {
        while ((getline l < f) > 0) {
            if (index(l, k "=") == 1) { sub(/\r$/, "", l); return substr(l, length(k) + 2) }
        }
        return ""
    }
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[[:cntrl:]]/, "", s); return s }
    function dump(f,   l, out, n, eq, k, v) {
        out = ""; n = 0
        while ((getline l < f) > 0) {
            sub(/\r$/, "", l)
            if (l ~ /^[ \t]*#/) continue
            eq = index(l, "=")
            if (eq == 0) continue
            k = substr(l, 1, eq - 1); v = substr(l, eq + 1)
            gsub(/^[ \t]+/, "", k); gsub(/[ \t]+$/, "", k)
            gsub(/^[ \t]+/, "", v); gsub(/[ \t]+$/, "", v)
            if (k == "") continue
            out = out (n++ ? "," : "") "\"" esc(k) "\":\"" esc(v) "\""
        }
        return out
    }
    BEGIN {
        cur = dump(OPT)
        dflt = dump(DEF)
        printf "{\"ok\":true,\"exists\":true,\"config\":{%s},\"defaults\":{%s}}", cur, dflt
    }'
}

api_config_save() {
    # $1 = raw body (K=V&...)
    if [ ! -f "$OPT_FILE" ]; then
        http_err 400 "Bad Request" "option.txt 不存在，请先安装 charge-control 模块"
        return
    fi
    BODY_FILE="$TCP_DIR/.body.tmp"
    TMP_OUT="$TCP_DIR/.option.tmp"
    printf '%s' "$1" > "$BODY_FILE"
    rm -f "$TMP_OUT"

    RESP=$("$BUSYBOX" awk -v BODYF="$BODY_FILE" -v OUT="$TMP_OUT" '
    function allowed(k) {
        return index(" CYCLE_TIME FORCE_TEMP CURRENT_MAX STEP_CHARGING_DISABLED TEMP_CTRL POWER_CTRL STEP_CHARGING_DISABLED_THRESHOLD CHARGE_STOP CHARGE_START TEMP_MAX HIGHEST_TEMP_CURRENT RECHARGE_TEMP BYPASS_CHARGE ", " " k " ") > 0
    }
    function hexval(h,   i, c, d) {
        d = 0
        for (i = 1; i <= 2; i++) {
            c = tolower(substr(h, i, 1))
            d = d * 16 + index("0123456789abcdef", c) - 1
        }
        return sprintf("%c", d)
    }
    FILENAME == BODYF { body = body $0 "\n"; next }
    { lines[++n] = $0 }
    END {
        s = body
        gsub(/\+/, " ", s)
        dec = ""
        while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
            dec = dec substr(s, 1, RSTART - 1) hexval(substr(s, RSTART + 1, 2))
            s = substr(s, RSTART + 3)
        }
        dec = dec s

        np = split(dec, pairs, "&")
        nk = 0
        for (i = 1; i <= np; i++) {
            p = pairs[i]
            if (p == "") continue
            e = index(p, "=")
            if (e == 0) continue
            k = substr(p, 1, e - 1); v = substr(p, e + 1)
            gsub(/^[ \t]+/, "", k); gsub(/[ \t]+$/, "", k)
            gsub(/^[ \t\r\n]+/, "", v); gsub(/[ \t\r\n]+$/, "", v)
            if (!allowed(k)) { bad = bad (bad == "" ? "" : ",") "\"" k "\""; continue }
            if (v !~ /^[0-9]+$/) { bad = bad (bad == "" ? "" : ",") "\"" k "\""; continue }
            v = v + 0
            if (v > 2147483647) { bad = bad (bad == "" ? "" : ",") "\"" k "\""; continue }
            if (k == "CYCLE_TIME" && v < 1) v = 1
            if (!(k in want)) { keys[++nk] = k }
            want[k] = v
        }

        if (nk > 0) {
            for (i = 1; i <= n; i++) {
                L = lines[i]
                if (L ~ /^[ \t]*#/ || index(L, "=") == 0) { print L > OUT; continue }
                kk = L
                sub(/=.*$/, "", kk)
                gsub(/^[ \t]+/, "", kk); gsub(/[ \t]+$/, "", kk)
                if (kk in want) { print kk "=" want[kk] > OUT; seen[kk] = 1 }
                else print L > OUT
            }
            for (i = 1; i <= nk; i++) {
                kk = keys[i]
                if (!(kk in seen)) print kk "=" want[kk] > OUT
            }
            close(OUT)
        }

        kstr = ""
        for (i = 1; i <= nk; i++) kstr = kstr (i > 1 ? "," : "") "\"" keys[i] "\""
        printf "{\"ok\":true,\"saved\":%d,\"keys\":[%s],\"ignored\":[%s]}", nk, kstr, bad
    }' "$BODY_FILE" "$OPT_FILE" 2>/dev/null)

    rm -f "$BODY_FILE"
    if [ -z "$RESP" ]; then
        http_err 500 "Internal Server Error" "配置解析失败"
        return
    fi
    if [ -s "$TMP_OUT" ]; then
        cp -f "$OPT_FILE" "$OPT_BAK" 2>/dev/null
        mv -f "$TMP_OUT" "$OPT_FILE" 2>/dev/null || cp -f "$TMP_OUT" "$OPT_FILE"
        chmod 0666 "$OPT_FILE" 2>/dev/null
    fi
    rm -f "$TMP_OUT"
    http_send "$RESP"
}

api_config_reset() {
    # $1 = src (bak|default)
    SRC="$1"
    if [ "$SRC" = "default" ]; then
        if [ ! -f "$OPT_DEF" ]; then
            http_err 400 "Bad Request" "默认配置不存在，请重新安装模块"
            return
        fi
        cp -f "$OPT_FILE" "$OPT_BAK" 2>/dev/null
        cp -f "$OPT_DEF" "$OPT_FILE" 2>/dev/null
        chmod 0666 "$OPT_FILE" 2>/dev/null
        http_send '{"ok":true,"msg":"已恢复默认配置"}'
        return
    fi
    if [ ! -f "$OPT_BAK" ]; then
        http_err 400 "Bad Request" "还没有可回滚的备份"
        return
    fi
    cp -f "$OPT_BAK" "$OPT_FILE" 2>/dev/null
    chmod 0666 "$OPT_FILE" 2>/dev/null
    http_send '{"ok":true,"msg":"已回滚到上一次保存前"}'
}

api_bypass_get() {
    if [ ! -f "$BYPASS_FILE" ]; then
        printf '%s' '{"ok":true,"exists":false,"apps":[]}'
        return
    fi
    "$BUSYBOX" awk -v F="$BYPASS_FILE" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    BEGIN {
        out = ""; n = 0
        while ((getline l < F) > 0) {
            sub(/\r$/, "", l)
            gsub(/^[ \t]+/, "", l); gsub(/[ \t]+$/, "", l)
            if (l == "" || l ~ /^#/) continue
            out = out (n++ ? "," : "") "\"" esc(l) "\""
        }
        printf "{\"ok\":true,\"exists\":true,\"apps\":[%s]}", out
    }'
}

api_bypass_save() {
    # $1 = raw body (text=...)
    BODY_FILE="$TCP_DIR/.body.tmp"
    TMP_OUT="$TCP_DIR/.bypass.tmp"
    printf '%s' "$1" > "$BODY_FILE"
    rm -f "$TMP_OUT"

    RESP=$("$BUSYBOX" awk -v BODYF="$BODY_FILE" -v OUT="$TMP_OUT" -v SRCF="$BYPASS_FILE" '
    function hexval(h,   i, c, d) {
        d = 0
        for (i = 1; i <= 2; i++) {
            c = tolower(substr(h, i, 1))
            d = d * 16 + index("0123456789abcdef", c) - 1
        }
        return sprintf("%c", d)
    }
    FILENAME == BODYF { body = body $0 "\n"; next }
    { keep[++nk] = $0 }
    END {
        s = body
        gsub(/\+/, " ", s)
        dec = ""
        while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
            dec = dec substr(s, 1, RSTART - 1) hexval(substr(s, RSTART + 1, 2))
            s = substr(s, RSTART + 3)
        }
        dec = dec s

        gsub(/\r/, "\n", dec)
        np = split(dec, raw, "\n")
        cnt = 0
        for (i = 1; i <= np; i++) {
            v = raw[i]
            gsub(/^[ \t]+/, "", v); gsub(/[ \t\r]+$/, "", v)
            if (v == "" || v ~ /^#/) continue
            if (v !~ /^[A-Za-z0-9._]+$/ || index(v, ".") == 0) {
                bad = bad (bad == "" ? "" : ",") "\"" v "\""
                continue
            }
            if (v in seen) continue
            seen[v] = 1
            list[++cnt] = v
        }

        # 保留原文件的注释头
        for (i = 1; i <= nk; i++) {
            L = keep[i]
            if (L ~ /^[ \t]*#/) print L > OUT
        }
        print "" > OUT
        for (i = 1; i <= cnt; i++) print list[i] > OUT
        close(OUT)

        lstr = ""
        for (i = 1; i <= cnt; i++) lstr = lstr (i > 1 ? "," : "") "\"" list[i] "\""
        printf "{\"ok\":true,\"count\":%d,\"apps\":[%s],\"ignored\":[%s]}", cnt, lstr, bad
    }' "$BODY_FILE" "$BYPASS_FILE" 2>/dev/null)

    rm -f "$BODY_FILE"
    if [ -z "$RESP" ]; then
        http_err 500 "Internal Server Error" "解析失败"
        return
    fi
    if [ -s "$TMP_OUT" ]; then
        mv -f "$TMP_OUT" "$BYPASS_FILE" 2>/dev/null || cp -f "$TMP_OUT" "$BYPASS_FILE"
        chmod 0666 "$BYPASS_FILE" 2>/dev/null
    fi
    rm -f "$TMP_OUT"
    http_send "$RESP"
}

api_log() {
    SRC="${1:-cur}"
    LINES="${2:-200}"
    case "$LINES" in ''|*[!0-9]*) LINES=200 ;; esac
    [ "$LINES" -lt 10 ] 2>/dev/null && LINES=10
    [ "$LINES" -gt 2000 ] 2>/dev/null && LINES=2000

    F="$TC_LOG"
    [ "$SRC" = "old" ] && F="$TC_LOG_OLD"

    if [ ! -f "$F" ]; then
        http_send "（暂无日志：$F）" "text/plain; charset=utf-8"
        return
    fi
    BODY=$("$BUSYBOX" tail -n "$LINES" "$F" 2>/dev/null)
    [ -z "$BODY" ] && BODY="（日志为空）"
    http_send "$BODY" "text/plain; charset=utf-8"
}

api_log_clear() {
    if [ -f "$TC_LOG" ]; then
        : > "$TC_LOG"
        http_send '{"ok":true,"msg":"日志已清空"}'
    else
        http_err 400 "Bad Request" "日志文件不存在"
    fi
}

# ---------- 请求处理 ----------

read_body() {
    # $1 = content-length
    CLEN="$1"
    case "$CLEN" in ''|*[!0-9]*) CLEN=0 ;; esac
    [ "$CLEN" -gt 65536 ] 2>/dev/null && CLEN=65536
    if [ "$CLEN" -gt 0 ] 2>/dev/null; then
        BODY=$("$BUSYBOX" dd bs=1 count="$CLEN" 2>/dev/null)
    else
        BODY=""
    fi
}

handle_request() {
    request_line=""
    read -r request_line || return
    set -- $request_line
    req_method="${1:-GET}"
    req_url="${2:-/}"

    req_path="${req_url%%\?*}"
    QUERY=""
    case "$req_url" in *\?*) QUERY="${req_url#*\?}" ;; esac

    # 读取请求头
    CLEN=0
    while IFS= read -r hdr; do
        hdr="${hdr%$CR}"
        [ -z "$hdr" ] && break
        case "$hdr" in
            [Cc]ontent-[Ll]ength:*)
                CLEN="${hdr#*:}"
                set -- $CLEN
                CLEN="${1:-0}"
                ;;
        esac
    done

    BODY=""
    if [ "$req_method" = "POST" ] || [ "$req_method" = "PUT" ]; then
        read_body "$CLEN"
    fi

    case "$req_method" in
        OPTIONS)
            http_head "204 No Content" "text/plain; charset=utf-8" "0"
            return
            ;;
    esac

    case "$req_path" in
        /|/index.html|/panel.html|/webroot/index.html|/webroot/panel.html)
            serve_file "$WEBROOT" "text/html; charset=utf-8"
            ;;
        /favicon.ico)
            http_head "204 No Content" "image/x-icon" "0"
            ;;
        /api/ping)
            api_ping
            ;;
        /api/info)
            api_info
            ;;
        /api/status)
            http_send "$(api_status)"
            ;;
        /api/config)
            if [ "$req_method" = "POST" ]; then api_config_save "$BODY"; else http_send "$(api_config_get)"; fi
            ;;
        /api/config/reset)
            if [ "$req_method" = "POST" ]; then
                case "$QUERY" in
                    *src=default*) api_config_reset default ;;
                    *) api_config_reset bak ;;
                esac
            else
                http_err 405 "Method Not Allowed" "请使用 POST"
            fi
            ;;
        /api/bypass)
            if [ "$req_method" = "POST" ]; then api_bypass_save "$BODY"; else http_send "$(api_bypass_get)"; fi
            ;;
        /api/log)
            api_log "$(case "$QUERY" in *src=old*) echo old ;; *) echo cur ;; esac)" \
                    "$(case "$QUERY" in *n=*) _q="${QUERY#*n=}"; echo "${_q%%&*}" ;; *) echo 200 ;; esac)"
            ;;
        /api/log/clear)
            if [ "$req_method" = "POST" ]; then api_log_clear; else http_err 405 "Method Not Allowed" "请使用 POST"; fi
            ;;
        *)
            http_err 404 "Not Found" "Not Found"
            ;;
    esac
}

handle_request
