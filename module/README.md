# 充电调控（内置 WebUI 控制面板）· 二改版

在原版 [turbo-charge v68](https://github.com/chase535/turbo-charge)（酷安 @诺鸡鸭）基础上内置了 WebUI 控制面板，由 **Yxlan-yu** 二改整合。

> 原版模块功能：删除温控，关闭阶梯式充电，持续修改电池温度及充电电流，尽可能让手机满血快充。

## 界面预览（v1.2）

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

## 零监听端口（v1.1 核心变更）

v1.0 的做法是「本机回环 `127.0.0.1` + iptables 拦截外部来源」，能挡住局域网，但**挡不住本机其它 App**：本机 App 连 `127.0.0.1:8080` 时源地址就是 `127.0.0.1`，那条 `! -s 127.0.0.1 -j DROP` 规则天然匹配不上，而面板接口没有鉴权 —— 也就是说任何有网络权限的本机应用都能改你的充电配置、清你的日志。

v1.1 直接把端口拿掉了：

- **模块不再监听任何端口、不创建任何 socket**，`nc` / `iptables` / 看门狗 / `webui.log` 全部移除。
- 面板通过模块管理器（KernelSU / SukiSU / KernelSU-Next）注入的 `ksu.exec`，在 root shell 里执行 `api_cli.sh` 拿数据；请求根本不经过网络栈，**外部没有任何端口可连、可扫、可爆破**。
- `api_cli.sh` 只做一件事：把「路径 + 方法 + base64 请求体」拼成一次内部请求喂给 `http_api.sh`。路由、白名单、数值校验、原子写入这些逻辑与 v1.0 **逐字节一致**，只是入口从 socket 换成了命令行。
- 顺带的好处：不再出现「8080 被别的软件占用导致面板打不开」，也不再需要 `adb forward`。

### 取舍（务必知道）

- **只能在管理器里打开面板**。面板不再是网页服务，浏览器直接访问 `http://手机IP:8080` 或 `http://127.0.0.1:8080` 都会失败（这是设计如此，不是 bug）。
- **Magisk 用户看不到面板**：Magisk 管理器没有 WebUI 入口，也没有 `ksu.exec`。Magisk 下模块本体（充电控制）照常工作，改参数请直接编辑 `/data/adb/turbo-charge/option.txt`。
- **每次请求要在 root shell 里 fork 一次**，刷新耗时比本地 HTTP 略高（v1.2 起首屏只发 1 次请求，轮询仍是每秒 1 次状态读取），换来的是零端口暴露。
- 极老的 KernelSU 版本 `ksu.exec` 签名不一致时面板会提示连不上；本面板做了三种调用形态的回退（对象回调 / 字符串回调 / 布尔返回），并会在 `/modules/` 路径不存在时自动改走 `/modules_update/`。

## 首屏加载（v1.2 优化）

v1.0 / v1.1 打开面板时要发 **5 次 `ksu.exec`**（ping + info + status + config + bypass）。管理器是串行执行 `ksu.exec` 的，每次都要重新 `fork` 一个 root shell 跑 `api_cli.sh` → `http_api.sh` → `busybox`，5 次就是 5 份开销相加 —— 这就是「每次退出管理器再进来都要等一下」的来源（`正在连接` 那一层之后的数据加载）。

v1.2 做了两件事：

1. **合并接口 `/api/snapshot`**：一次往返就把 `info` + `status` + `config` + `bypass` 四份数据全拿回来，首屏请求数 **5 → 1**。字段就是原来四个接口的原文拼装，没有新增配置项、没有改写入逻辑。
2. **本地快照缓存**：拿到真实数据后把快照存进 `localStorage`（键 `tc.snap`，超过 1 天作废，轮询时至少间隔 15 秒才更新一次）。下次再打开面板，**先用缓存把概览 / 参数 / 日志画出来**，等真实数据到手再覆盖 —— 于是页面是「立刻有内容」，而不是「先空着等转圈」。

两条不可见的约束（保证不骗人）：

- 缓存**只负责先画**：不置连接成功、不启动轮询、不显示传输方式，真实数据没到手前页脚仍然显示读取中。
- **旧模块 + 新前端也能用**：`/api/snapshot` 不存在时会自动退回 `/api/ping` 探测，然后按老办法逐条加载。

## 稳定性

- **不再有常驻进程**：v1.0 的 `nc` 看门狗与日志轮转随端口一起删除，少一个会挂的东西。
- **旧版遗留自动清理**：升级到 v1.1 后，`service.sh` 会删掉 v1.0 留下的 iptables 规则、按 `/proc/$PID/cmdline` 校验后杀掉残留的 `nc` 进程，并删除 `webui.iptables` / `webui.pid`。
- **单文件面板**：整个前端只有一个 `webroot/index.html`（无外链、无 CDN），离线可用。
- **面板自身容错**：`ksu.exec` 20 秒无响应会明确报错而不是无限转圈；管理器环境判定成立时不会再去白等 iframe 桥接。

## 打开方式

安装模块后：

```
KernelSU / SukiSU / KernelSU-Next 管理器 → 本模块 → 打开（WebUI）
```

面板顶栏副标题在管理器内只显示版本号（例如 `v1.2`），`设备信息 → 连接方式` 一行默认隐藏；只有在降级的 iframe 桥接 / 回环 HTTP 模式下才会显示传输方式，用于排障。

> 浏览器直接打开 `http://手机IP:8080`、`adb forward` 之类的老办法**在 v1.1 全部失效**。
> 所有设备信息均在本机处理，不做任何上传。

## 安装方法

- **KernelSU / SukiSU / KernelSU-Next / Magisk**：管理器内直接安装本 zip 即可（Magisk 下无面板，见上文）。
- **升级**：模块 id 为 `charge-control`，同 id 直接覆盖安装，原配置文件会自动读取合并，未识别的项回落默认值。
- **从 v1.0 升级**：直接覆盖安装即可；安装完成后重启一次，`service.sh` 会在开机时清理旧的端口与防火墙残留。
- **从旧版（`turbo-charge`）迁移**：项目已由 `turbo-charge-webui` 更名为 **charge-control（充电调控）**，模块 id 也从 `turbo-charge` 改成 `charge-control`。**管理器不认为这是同一个模块**，所以请先卸载旧模块再安装本模块。
  - 安装脚本会主动清理 `/data/adb/modules/turbo-charge` 与 `/data/adb/modules_update/turbo-charge`，避免两份 `service.sh` 同时运行；
  - 旧配置目录 `/data/adb/turbo-charge` **不会删**，安装时会原样读入，参数不用重新填。
- **卸载**：在管理器里卸载模块，配置目录 `/data/adb/turbo-charge` 会一并清理；v1.0 遗留的 iptables 规则也会被撤销。

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
| `/data/adb/modules/charge-control/` | 模块目录（管理器安装位置） |
| `/data/adb/modules/charge-control/api_cli.sh` | 面板的命令行入口（`ksu.exec` 调用它） |
| `/data/adb/modules/charge-control/http_api.sh` | 路由与校验（v1.0 原样复用） |
| `/data/adb/turbo-charge/option.txt` | 当前配置 |
| `/data/adb/turbo-charge/option.txt.bak` | 上次保存前的备份（可回滚） |
| `/data/adb/turbo-charge/option.txt.default` | 出厂默认配置（可恢复默认） |
| `/data/adb/turbo-charge/bypass_charge.txt` | 伪旁路包名列表 |
| `/data/adb/turbo-charge/log.txt` | 模块运行日志 |
| `/data/adb/turbo-charge/log.txt.old` | 上一次开机的日志 |

> ⚠️ `/data/adb/turbo-charge` 这个目录名**不能改**：原版预编译二进制 `turbo-charge` 内部硬编码了该路径（`option.txt` / `bypass_charge.txt`），改名会导致核心直接读不到配置。项目更名只改了模块 id 与显示名，配置目录保持原样。

## 接口（仅管理器内可达）

接口与 v1.0 相同（v1.2 新增一个只读的 `/api/snapshot` 合并入口），只是入口从 HTTP 端口换成了 `api_cli.sh <路径?查询> <方法> [base64 请求体]`：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ping` | 健康检查（`port` 恒为 0，表示非端口模式） |
| GET | `/api/snapshot` | 首屏合并：`info` + `status` + `config` + `bypass` 一次返回（仅 GET，其它方法 405） |
| GET | `/api/info` | 模块 / 设备 / 功能可用性 |
| GET | `/api/status` | 实时充电状态 + 生效策略 |
| GET | `/api/config` | 配置项 + 默认值 |
| POST | `/api/config` | 保存配置（form `K=V&K2=V2`） |
| POST | `/api/config/reset` | `src=bak` 回滚备份 / `src=default` 恢复默认 |
| GET | `/api/bypass` | 旁路供电包名列表 |
| POST | `/api/bypass` | 保存包名列表（form `text=...`） |
| GET | `/api/log?n=200&src=cur\|old` | 读取日志（n 钳制 10–2000） |
| POST | `/api/log/clear` | 清空当前日志 |

> 没有鉴权也不需要鉴权：没有端口，就没有「谁都能连」的入口。

## 常见问题

**Q：为什么浏览器打不开面板了？**
A：v1.1 不再监听端口，浏览器没有 `ksu.exec` 权限，从根上连不进模块。请在管理器里打开。

**Q：Magisk 下怎么改参数？**
A：直接编辑 `/data/adb/turbo-charge/option.txt`（16 进制无关，纯 `KEY=VALUE` 文本），改完等下一轮循环（默认 1 秒）生效，或重启。

**Q：副标题显示「桥接」或「端口 8787」是什么意思？**
A：说明当前不在管理器里，页面退回了 iframe 桥接（本地调试用）或 v1.0 的回环端口——这两种降级模式才会显示传输方式。真机管理器内副标题只显示版本号，`设备信息` 里不会出现「连接方式」这一行。

**Q：升级后 8080 还被占用？**
A：那是 v1.0 遗留的 `nc` 进程，重启一次由 `service.sh` 清理；也可以手动 `su -c 'kill -9 $(cat /data/adb/turbo-charge/webui.pid)'`。

**Q：v1.2 首屏还是要等一下？**
A：首屏已经从 5 次请求压到 1 次，但每次请求仍要在 root shell 里 fork 一遍（真机单次约 0.2–0.6 秒，取决于 busybox 与调度）。所以做法是「缓存先画 + 真实数据后到」：页面立刻有内容，数字随后刷新成最新的。第一次安装（还没有缓存）必然是白纸起步，第二次之后才会明显变快。

## 与原版差异

1. 内置 WebUI 控制面板（概览 / 参数 / 日志 / 回滚 / 恢复默认）。
2. busybox 自动探测，兼容 KernelSU / KernelSU-Next / SUKISU / Magisk / 系统 busybox，无需额外安装。
3. **面板零监听端口**：经 `ksu.exec` 在 root shell 内直连 `api_cli.sh`，不开放任何端口、不创建 socket。
4. 模块更名为 **充电调控**，id 为 `charge-control`，版本号从 **v1.0** 重新计数。
5. 原版核心功能与配置格式保持不变。
6. **首屏一次请求拿齐四份数据并本地缓存**（v1.2），重新打开面板先用快照秒显示。

## 在线更新

`module.prop` 的 `updateJson` 指向本仓库自建的 [`update.json`](https://github.com/Yxlan-yu/charge-control/blob/main/update.json)：

- KernelSU / KernelSU-Next / Magisk 管理器打开模块详情时会读它，发现更大的 `versionCode` 就提示更新，并直接下载 Release 里的 zip。
- 本次发布是 `version=1.2` / `versionCode=3`，对应 [Release v1.2](https://github.com/Yxlan-yu/charge-control/releases/tag/v1.2)。
- 该地址走 `raw.githubusercontent.com`：**如果你的网络访问不了它，管理器内的更新检查会失败**（不影响模块本体运行），请直接到 [Releases](https://github.com/Yxlan-yu/charge-control/releases) 下载 zip 手动刷入。

## 开源协议

本二改版遵循原项目的 **AGPLv3** 开源协议。
原版作者：诺鸡鸭（酷安 [@诺鸡鸭](https://www.coolapk.com/u/1145497)）· [GitHub](https://github.com/chase535/turbo-charge)
