# 充电加速（内置 WebUI 控制面板）· 二改版

在原版 [turbo-charge v68](https://github.com/chase535/turbo-charge)（酷安 @诺鸡鸭）基础上内置了 WebUI 控制面板，由 **Yxlan-yu** 二改整合。

> 原版模块功能：删除温控，关闭阶梯式充电，持续修改电池温度及充电电流，尽可能让手机满血快充。

## 界面预览（v68-2）

控制面板按 **Miuix（HyperOS）** 风格重做：浅色 `#F2F3F5` 底 + 白色 20px 圆角卡片 + `#3482FF` 强调色，深色为纯黑底 + `#191A1C` 卡片 + `#4A8DFF` 强调色；顶部分段控件切换 **概览 / 参数 / 日志** 三个页面，主题支持 **跟随系统 / 浅色 / 深色**。

## WebUI 功能

### 概览

- **实时充电状态**：电量环、电压、电流、功率、电池温度、充电类型、健康度、PD 协商档位。
- **功率/温度走势图**：最近 90 次采样的双曲线走势（双 Y 轴归一化），切到别的页面会自动暂停取数，回到前台继续。
- **快捷开关**：温度伪装、高温限流、电量控制、阶梯充电、伪旁路 —— 点一下即写入配置，无需翻参数页。
- **当前生效策略**：把 option.txt 里真正生效的数值摊开显示，一眼看出模块在按什么规则跑。

### 参数

- **13 项参数在线编辑**，输入即生效：700ms 防抖自动保存，右上角提示「已保存」，不需要点按钮。
- **数值校验**：服务端只接受纯数字且 ≤ 2147483647，`CYCLE_TIME` 最小钳到 1；非法项会被忽略并回显提示，不会把错误值写进配置。
- **自动备份 + 回滚**：每次保存前把当前配置备份为 `option.txt.bak`，参数页可一键「回滚上次配置」。
- **恢复默认**：回到模块安装时的出厂默认值（`option.txt.default`）。
- **功能联动禁用**：设备不支持的项目（如没有阶梯充电节点、没有 USB 信息）会自动置灰，不会让你改一个没用的开关。
- **伪旁路包名编辑器**：一行一个包名，保存后写入 `bypass_charge.txt`，模块下一轮循环生效。

### 日志

- **本次 / 上次** 两份日志切换（`log.txt` / `log.txt.old`，每次开机自动把旧日志改名保留一份）。
- 行数可选 **100 / 200 / 500 / 1000**，支持 **自动刷新**、**一键复制**、**清空当前日志**。

### 稳定性

- **看门狗**：`service.sh` 每 30 秒巡检 WebUI 进程，进程掉了自动拉起；并校验 `/proc/$PID/cmdline` 防止 PID 复用误判。
- **日志轮转**：`webui.log` 超过 256KB 时只保留末尾 128KB，不会无限增长。
- **旧地址兼容**：`/panel.html` 与 `/webroot/*` 一律返回新的单页面板，老书签不会 404。
- **单文件面板**：整个前端只有一个 `webroot/index.html`（无外链、无 CDN），离线可用。

## 打开方式

安装模块后，手机和电脑（同一局域网）均可访问：

```
http://手机IP:8080
```

或直接打开 KernelSU / Magisk 管理器 → 本模块 → 打开 WebUI。

> 所有设备信息均在本机处理，不做任何上传。

## 安装方法

- **KernelSU / KernelSU-Next / Magisk**：管理器内直接安装本 zip 即可。
- **升级**：模块 id 保持一致（`turbo-charge`），直接覆盖安装，原配置文件会自动读取合并，未识别的项回落默认值。
- **卸载**：在管理器里卸载模块，配置目录 `/data/adb/turbo-charge` 会一并清理。

## 配置说明

配置文件：`/data/adb/turbo-charge/option.txt`（WebUI 面板内也可编辑）。

| 参数 | 默认值 | 说明 |
|---|---|---|
| CYCLE_TIME | 1 | 主循环间隔（秒） |
| FORCE_TEMP | 1 | 是否写入电池温度伪装（1 开 0 关） |
| CURRENT_MAX | 50000000 | 最大充电电流 (µA) |
| STEP_CHARGING_DISABLED | 0 | 是否关闭阶梯式充电（1 关 0 开） |
| TEMP_CTRL | 1 | 是否启用高温电流限制（1 开 0 关） |
| POWER_CTRL | 0 | 是否启用断电/恢复充电控制（1 开 0 关） |
| STEP_CHARGING_DISABLED_THRESHOLD | 15 | 阶梯充电关闭阈值（电量百分比） |
| CHARGE_STOP | 95 | 断电电量百分比（需 POWER_CTRL=1） |
| CHARGE_START | 80 | 恢复充电电量百分比（需 POWER_CTRL=1） |
| TEMP_MAX | 52 | 高温限制温度（℃） |
| HIGHEST_TEMP_CURRENT | 2000000 | 高温时允许的充电电流 (µA) |
| RECHARGE_TEMP | 45 | 高温限制解除温度（℃） |
| BYPASS_CHARGE | 0 | 伪旁路充电（1 开 0 关，电流降至 500mA） |

> 面板里电流以 **mA** 显示（内部 ×1000 存 µA），温度直接是 ℃。

## 相关文件

| 路径 | 说明 |
|---|---|
| `/data/adb/turbo-charge/option.txt` | 当前配置 |
| `/data/adb/turbo-charge/option.txt.bak` | 上次保存前的备份（可回滚） |
| `/data/adb/turbo-charge/option.txt.default` | 出厂默认配置（可恢复默认） |
| `/data/adb/turbo-charge/bypass_charge.txt` | 伪旁路包名列表 |
| `/data/adb/turbo-charge/log.txt` | 模块运行日志 |
| `/data/adb/turbo-charge/log.txt.old` | 上一次开机的日志 |
| `/data/adb/turbo-charge/webui.log` | WebUI 服务日志 |

## HTTP 接口（自用，局域网内可调）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ping` | 健康检查 |
| GET | `/api/info` | 模块 / 设备 / 功能可用性 |
| GET | `/api/status` | 实时充电状态 + 生效策略 |
| GET | `/api/config` | 配置项 + 默认值 |
| POST | `/api/config` | 保存配置（form `K=V&K2=V2`） |
| POST | `/api/config/reset` | `src=bak` 回滚备份 / `src=default` 恢复默认 |
| GET | `/api/bypass` | 旁路供电包名列表 |
| POST | `/api/bypass` | 保存包名列表（form `text=...`） |
| GET | `/api/log?n=200&src=cur\|old` | 读取日志（n 钳制 10–2000） |
| POST | `/api/log/clear` | 清空当前日志 |

> 接口无鉴权，仅监听本机 8080 端口；请勿把 8080 暴露到公网。

## 与原版差异

1. 内置 WebUI 控制面板（概览 / 参数 / 日志 / 回滚 / 恢复默认）。
2. busybox 自动探测，兼容 KernelSU / KernelSU-Next / Magisk / 系统 busybox，无需额外安装。
3. 版本号 `v68-2`，与原版 `v68` 区分。
4. 原版所有功能与配置格式保持不变，老用户升级无感。

## 开源协议

本二改版遵循原项目的 **AGPLv3** 开源协议。
原版作者：诺鸡鸭（酷安 [@诺鸡鸭](https://www.coolapk.com/u/1145497)）· [GitHub](https://github.com/chase535/turbo-charge)
