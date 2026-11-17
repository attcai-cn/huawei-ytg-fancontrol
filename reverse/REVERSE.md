# 本机风扇控制接口逆向记录（HUAWEI YTG-XXX / 擎云 QingYun）

逆向时间：2026-11-15（本机 HUAWEI YTG-XXX，主板 YTG-XXX-PCB M1010，BIOS 1.08，i7-1360P）

结论：**可以**。本机与仓库原有的 MateBook 14 2024（FlemingH）走同一套 `OemWMIfun` / `SFND` 通道，
命令字节布局完全一致；差异只在风扇数量（本机单风扇）和转速饱和点（本机约 5280 RPM）。

## 逆向路径

1. `root\wmi:OemWMIMethod` 存在实例 `ACPI\PNP0C14\HWMI_0`，与参考项目一致，先确认接口在。
2. 用只读命令验证协议：`02 02 05`（温度）、`02 08 00`（转速计）返回合理值。
3. 用 `acpidump -b` + `acpixtract` 抓取运行时 ACPI 表，`iasl -d` 反编译成 DSL。
4. 在 `SSDT (HUAWEI WmiTable)` 中找到 WMI 分发方法和 `SFND`，在 `DSDT (HUAWEI RPL-P)` 中找到
   `HWEC.ECCD` 与风扇设备，逐条读出命令解码逻辑。
5. 按固件逻辑构造命令，实机写入验证并恢复。

工具：`choco install iasl`（提供 `iasl` / `acpidump` / `acpixtract`）。

## 调用链

```
OemWMIfun(u8Input 64B)
  └─ WMAA(MFID=Arg2[0], SFID=Arg2[1])          SSDT WmiTable
       └─ SFND / GTMP / GFNS                    方法层，按字节解包
            └─ ECCM(a, b, len, payload)          统一封装：写入 3 字节头 + 数据，回读
                 └─ \_SB.PC00.LPCB.HWEC.ECCD     EC 控制器（端口 0x62/0x66）
```

`ECCM` 返回缓冲区的 `[0]` 是状态（0 成功），`[1]` 被固件清 0，真实数据从 `[2]` 开始，
因此 WMI 侧看到的 `u8Output[0]` 是状态、`u8Output[1..]` 是 EC 返回数据。

## 命令表

| WMI 命令 | 方法 | 下发到 EC | 说明 |
|---|---|---|---|
| `02 02 <sensor>` | GTMP | `02 61 01 <sensor>` | 读温度 |
| `02 08 <fan lo> <fan hi>` | GFNS | `02 7C 01 <fan>` | 读物理转速计 |
| `02 11 00 01 00 00` | SFND | `04 01 01 01` | 进入风扇测试模式 |
| `02 11 <fan> 01 <rpm lo> <rpm hi>` | SFND | `04 02 02 {fan, rpm/100}` | 设转速 |
| `02 11 00 00 00 00` | SFND | `04 01 01 00` | 退出测试模式，交还原厂 |

要点：

- `SFND` 读 `Arg0[2]` 作为风扇下标、`Arg0[3]` 作为模式（0 退出 / 1 设速）、`Arg0[4..5]` 作为
  **小端 16 位转速**，固件内部执行 `(high*256+low)/100` 后只把 `RPM/100` 送给 EC，
  所以**固件分辨率是 100 RPM**，可表达范围 0–25500 RPM。
- 温度返回：`out[1]` 符号（1 为负）、`out[2]` 整数℃、`out[3]` 小数位；
  固件内部按 0.1 ℃ 16 位小端取值后 `Divide` 10 拆开。
- `02 0A (GFRQ)` 是空实现，固定返回 0，不能用来读当前请求值。

## 本机与参考机型的差异

| 项目 | MateBook 14 2024 (FlemingH) | 本机 YTG-XXX (QingYun) |
|---|---|---|
| 风扇数量 | 2（Fan 0 / Fan 1） | **1**（Fan 1 转速计恒返回 0xFFFF，ACPI 里只有 `TFN1`） |
| 命令布局 | `02 11 <fan> 01 <lo> <hi>` | 相同 |
| 转速饱和 | ~7000–7200 RPM（请求 12000） | **~5280 RPM**（请求 ≥7400 无进一步变化） |
| ACPI 风扇设备 | `_FPS` 档位表 | `TFN1` (INTC1048) 有 `_FPS`、**无 `_FSL`**，只能经 WMI/EC 控制 |

ACPI 标准风扇接口走不通：`TFN1` 只有 `_STA`/`_FIF`/`_FPS`，没有 `_FSL`（设定档位）方法，
`_STA` 还依赖 EC 字段 `FND1`；`TFN2` 因 `FND2 != 1` 不呈现。Intel 参考 SSDT 里的
`FAN0..FAN4`(PNP0C0B) 是 DPTF 占位设备，动不了真实风扇，与参考项目结论一致。

## 温区实测（EC `02 61`，共 13 个有效传感器）

有效编号：`0, 5, 7, 8, 11, 14, 15, 18, 22, 25, 26, 29, 30, 31`（其余返回状态 1 = 不支持）。

典型读数与行为：

| 传感器 | 空载 | 风扇压到 3200 后 | 判断 |
|---|---:|---:|---|
| S0 | 66–72 ℃（秒级跳动） | 升到 74 ℃ | 最像 CPU/主板热点，响应最快 |
| S8 | 66 ℃ | 基本不动 | 机身/供电区 |
| S5 | 55–57 ℃ | 缓慢升到 57 ℃ | 平稳，适合做慢速曲线输入 |
| S7 | 48 ℃ | 不动 | 进风/环境侧 |

加压 16 进程跑满 60 秒时上述传感器几乎不变化，说明 EC 暴露的是机身/板级温度，
不是 die 温度；需要 die 温度得走 MSR 或厂商 PC Manager 的驱动通道。

## 转速跟随实测

请求值与稳定后物理转速（每档 5 个样本取平均）：

| 请求 RPM | 物理转速 | 备注 |
|---:|---:|---|
| 3200 | 3240 | 稳态，约 1:1 |
| 5100 | 5208 | 约 1:1 |
| 7400 | 5280 | 已饱和 |
| 9000 | 5280 | 已饱和 |
| 9300 | 5280 | 已饱和 |
| 12000 | 5280 | 已饱和 |
| 原厂空载 | 4620–4920 | 退出测试模式后自动回到该区间 |

风扇升降速有明显惯性：请求 3200 后约 10 秒才降到 3420，20 秒后稳定在 3240。
写入后必须留出观察窗口，不能按秒级闭环。

## 安全性

- 只写固件已经声明的 EC 命令，不直接写 EC RAM，不刷写 BIOS，不改电源策略。
- 进入测试模式是全局状态，本机只有一个风扇，退出即恢复原厂自动。
- 实机测试全程温度 55–74 ℃，未触发任何保护；脚本内保留 88 ℃ 紧急退出。
- 若控制器被强杀，EC 会停在最后一次目标转速；重启后 EC 复位回到原厂控制。

## 复现

```powershell
# 只读状态：温度 + 转速计 + 风扇存在性
.\reverse\HwFan-Probe.ps1 -Action Status

# 持续监测
.\reverse\HwFan-Probe.ps1 -Action Monitor -SampleSeconds 1

# 接管测试：请求 9000，保持 20 秒后自动恢复原厂
.\reverse\HwFan-Probe.ps1 -Action SetRpm -Rpm 9000 -HoldSeconds 20 -Apply

# 档位校准：3200 / 5100 / 7400 / 9300 / 12000
.\reverse\HwFan-Probe.ps1 -Action Calibrate -Apply
```

写入动作需要管理员 PowerShell 并显式传入 `-Apply`。

## 复现逆向过程

```powershell
choco install iasl -y
mkdir reverse\acpidump; cd reverse\acpidump
acpidump -b
iasl -d ssdt8.dat          # 含 WMI 分发与 SFND 的 SSDT (HUAWEI WmiTable)
iasl -d dsdt.dat           # 含 HWEC.ECCD 与 TFN1 风扇设备
```

`reverse/acpi` 与 `reverse/acpidump` 已被 `.gitignore` 排除，避免把本机固件提取物提交到仓库。
