# Huawei YTG Fan Control

`HUAWEI YTG-XXX`（擎云 QingYun，i7-1360P，BIOS 1.08，单风扇）的风扇控制，只提供两档：**最高转速**与**恢复自动控制**。

---

## 使用教程

### 第 1 步：下载需要的文件

在仓库页面点 **Code → Download ZIP**，解压后即得到全部文件。也可以逐个点击文件名，在页面右上角点 **Download raw file** 单独下载。

日常使用只需要下面 **2 个文件**，且必须放在**同一个文件夹**里：

| 文件 | 作用 |
|---|---|
| `Fan-Tray.cmd` | 启动托盘图标（日常用这个） |
| `HuaweiFan-Tray.ps1` | 托盘程序的脚本本体，由上面那个文件调用 |

如果不想用托盘，也可以额外下载命令行版：

| 文件 | 作用 |
|---|---|
| `Fan-Max.cmd` + `HuaweiFan-Max.ps1` | 直接切到最高转速，窗口里显示转速变化 |
| `Fan-Auto.cmd` | 直接恢复自动控制，不经过托盘 |

> 注意：`.cmd` 是靠同目录下的 `.ps1` 工作的，两个文件拆开放会报「找不到文件」。不要只下载 `.cmd`。

### 第 2 步：双击 `Fan-Tray.cmd`

1. 弹出 UAC 提示，点 **是**（必须管理员权限，否则写不了 EC）。
2. 右下角出现**风扇图标**：红色＝最高转速，绿色＝自动控制。
3. 鼠标悬停在图标上，可看到当前转速与温度。

### 第 3 步：点图标切换

左键或右键点击图标，弹出菜单：

```
状态：自动控制　4800 RPM　70 ℃
────────────────
✓ 最高转速
  恢复自动控制
────────────────
  退出
```

- 点 **最高转速** → 风扇立刻升到物理上限（本机约 5280 RPM），图标变红。
- 点 **恢复自动控制** → 交回固件控制，图标变绿，几秒内回落到 4600–4900 RPM。
- 点 **退出** → 会问你是否先恢复自动控制。

### 常见问题

| 现象 | 处理 |
|---|---|
| 双击后一闪而过 | 没点 UAC 的「是」，或文件没放在同一文件夹 |
| 提示「风扇托盘已经在运行了」 | 已经启动过了，看右下角托盘，不要重复开 |
| 图标找不到 | 可能在托盘折叠区（`^`）里，拖出来固定 |
| 想切回自动但托盘关了 | 双击 `Fan-Auto.cmd`，或重启电脑 |

**重要**：手动模式是持久的，关闭托盘窗口不会自动恢复，必须点「恢复自动控制」或重启。

---

## 为什么只有两档

固件协议能表达 0–25500 RPM，但物理上真正有用的区间很窄：

| 层面 | 区间 | 说明 |
|---|---|---|
| 物理可控 | 约 3200–5280 RPM | 请求与实际约 1:1 |
| 饱和上限 | ≈5280 RPM | 请求 ≥5300 无任何变化 |
| 原厂自动 | 4620–4920 RPM | 退出手动模式后回到此区间 |

所以只有两头有意义：**约 3200 RPM 的静音**和 **5280 RPM 的全速**。「最高转速」档请求 12000，只是为了确保触到上限。

## 工作原理

调用链（ACPI 反编译确认）：

```
OemWMIfun → WMAA(MFID, SFID) → SFND → ECCM → \_SB.PC00.LPCB.HWEC.ECCD → EC(0x62/0x66)
```

| 操作 | WMI 命令 |
|---|---|
| 进入手动模式 | `02 11 00 01 00 00` |
| 设置转速 | `02 11 <fan> 01 <rpm lo> <rpm hi>` |
| 恢复自动 | `02 11 00 00 00 00` |
| 读转速 | `02 08 <fan>` |
| 读温度 | `02 02 <sensor>` |

固件把 16 位转速值除以 100 再下发 EC，所以分辨率 100 RPM。本机只有 Fan 0，Fan 1 转速计恒返回 `0xFFFF`。

不写未知 EC RAM、不刷 BIOS、不改电源策略。完整逆向过程（ACPI 导出、`iasl` 反编译、逐字节解读、传感器实测）见 [`reverse/REVERSE.md`](reverse/REVERSE.md)。

## 进阶：脚本与探测

需要无界面调用或自己复现逆向时：

```powershell
.\HuaweiFan-Tray.ps1 -Action Max        # 最高转速
.\HuaweiFan-Tray.ps1 -Action Auto       # 恢复自动
.\HuaweiFan-Tray.ps1 -Action Status     # 只读状态

.\reverse\HwFan-Probe.ps1 -Action Status
.\reverse\HwFan-Probe.ps1 -Action SetRpm -Rpm 9000 -HoldSeconds 20 -Apply
```

`reverse/HwFan-Probe.ps1` 的写入动作需管理员权限并显式传 `-Apply`，内置 88 °C 紧急退出。

## 要求

- Windows PowerShell 5.1 或更高版本
- 管理员权限
- `root\wmi:OemWMIMethod` 中存在实例 `ACPI\PNP0C14\HWMI_0`

> [!WARNING]
> 只在 `HUAWEI YTG-XXX`（i7-1360P / BIOS 1.08）上验证。其他机型的接口、档位、风扇数量都可能不同，直接套用有风险。风扇控制失误可能导致过热、降频或硬件损伤，请自行承担。

## 数据与隐私

仓库不含 BIOS 镜像、ACPI 提取物或设备序列号。逆向时导出的 ACPI 表保存在本地 `reverse/acpi`、`reverse/acpidump`，已被 `.gitignore` 排除。

`HuaweiFan-Tray.ps1` 以 UTF-8 BOM 保存——PowerShell 5.1 对无 BOM 的中文脚本会按 GBK 解析并报语法错误，修改时请保持编码。

## 致谢

接口逆向思路参考了 [limsaiful42-eng/huawei-matebook-fancontrol](https://github.com/limsaiful42-eng/huawei-matebook-fancontrol)（Huawei MateBook 14 2024 双风扇控制项目），在此致谢。

本仓库的代码针对本机 `HUAWEI YTG-XXX` 重新实现，提交历史独立，不代表上游项目；上游的双风扇控制器、watchdog、图形界面与曲线配置均未包含。
