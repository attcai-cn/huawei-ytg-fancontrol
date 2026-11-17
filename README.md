# Huawei YTG Fan Control

针对 `HUAWEI YTG-XXX`（擎云 QingYun 系列，i7-1360P，BIOS 1.08）的风扇控制适配，只保留两档：**最高转速**与**恢复自动控制**。

控制器调用固件自带的 `OemWMIfun` / `SFND` 路径，经 `\_SB.PC00.LPCB.HWEC.ECCD` 访问 EC；不写未知 EC RAM 地址，不修改或刷写 BIOS，也不需要内核驱动。

本机为**单风扇**：只写 Fan 0，Fan 1 转速计恒返回 `0xFFFF`。物理上限约 5280 RPM，请求 ≥5300 RPM 全部饱和在此值。完整的逆向结论见 [`reverse/REVERSE.md`](reverse/REVERSE.md)。

> [!WARNING]
> 本机控制依赖特定的机型、主板与 BIOS 版本。其他机型可能接口不同、档位不同甚至风扇数量不同。风扇控制失误可能导致过热、降频或硬件损伤；请先确认机型，并自行承担使用风险。

## 用法

双击 `Fan-Tray.cmd`（会自动请求管理员权限），右下角出现风扇托盘图标：

- 红色图标 = 最高转速，绿色 = 固件自动控制；悬停显示当前转速与温度。
- 左键或右键点击图标打开菜单，在「最高转速」和「恢复自动控制」之间切换。
- 「退出」会询问是否先恢复自动控制。

也可以直接双击 `Fan-Max.cmd` / `Fan-Auto.cmd`，或在管理员 PowerShell 中调用：

```powershell
.\HuaweiFan-Tray.ps1                    # 托盘模式
.\HuaweiFan-Tray.ps1 -Action Max        # 无界面：最高转速
.\HuaweiFan-Tray.ps1 -Action Auto       # 无界面：恢复自动
.\HuaweiFan-Tray.ps1 -Action Status     # 只读状态
.\HuaweiFan-Max.ps1                     # 最高转速（带转速观察输出）
.\Restore-HuaweiFanVendorControl.ps1    # 恢复自动
```

手动模式是持久的：退出脚本或关闭托盘后风扇仍保持最后一次目标转速，直到执行恢复、重启，或在托盘退出时选择恢复。

## 可控转速区间

固件协议可表达 0–25500 RPM（16 位小端值 ÷ 100，分辨率 100 RPM），但物理有效区间要窄得多：

| 层面 | 区间 | 说明 |
|---|---|---|
| 物理可控 | 约 3200–5280 RPM | 线性跟随段，请求与实际约 1:1 |
| 饱和上限 | ≈5280 RPM | 请求 ≥5300 无进一步变化 |
| 原厂自动 | 4620–4920 RPM | 退出手动模式后回到此区间 |

因此真正有用的只有两头：静音约 3200 RPM，全速 5280 RPM。「最高转速」档请求 12000 只是为了触到物理上限。

## 逆向探测工具

`reverse/HwFan-Probe.ps1` 提供了只读探测和写入校准，写入需管理员权限并显式传 `-Apply`：

```powershell
.\reverse\HwFan-Probe.ps1 -Action Status
.\reverse\HwFan-Probe.ps1 -Action Monitor -SampleSeconds 1
.\reverse\HwFan-Probe.ps1 -Action SetRpm -Rpm 9000 -HoldSeconds 20 -Apply
.\reverse\HwFan-Probe.ps1 -Action Calibrate -Apply
```

## 要求

- Windows PowerShell 5.1 或更高版本
- 管理员权限
- `root\wmi:OemWMIMethod` 中存在实例 `ACPI\PNP0C14\HWMI_0`

## 安全机制

- 只写固件已声明的 EC 命令，不直接写 EC RAM，不刷写 BIOS，不改电源策略。
- 本机只有一个风扇，退出测试模式即恢复原厂自动。
- 探测脚本内置 88 °C 紧急退出。
- 若控制器被强杀，EC 会停在最后一次目标转速；重启后 EC 复位回到原厂控制。

## 数据与隐私

仓库不包含 BIOS 镜像、ACPI 提取物、设备序列号或电源设置快照。逆向过程中导出的 ACPI 表保存在本地 `reverse/acpi` 与 `reverse/acpidump`，已通过 `.gitignore` 排除；WorkBuddy 私有数据目录 `.workbuddy` 同样被排除。

托盘脚本里的 .ps1 以 UTF-8 BOM 保存：PowerShell 5.1 对无 BOM 的 UTF-8 会按 GBK 解析，导致含中文的脚本出现语法错误。

## 致谢

本项目的接口逆向思路与部分通用组件参考了 [limsaiful42-eng/huawei-matebook-fancontrol](https://github.com/limsaiful42-eng/huawei-matebook-fancontrol)（Huawei MateBook 14 2024 双风扇控制项目），在此致谢。

本仓库针对本机 `HUAWEI YTG-XXX` 做了单风扇两档适配与重新整理，提交历史独立，不代表上游项目。仓库中仍保留了若干上游通用文件（自动曲线控制器、watchdog、图形界面启动器、曲线配置等），这些面向 **MateBook 14 2024（FlemingH）/ BIOS 1.22 双风扇机型**，本机 YTG-XXX 未启用。

上游项目的验收记录见 [`VALIDATION.md`](VALIDATION.md) 与 [`CHANGELOG.md`](CHANGELOG.md)，仅供对照参考。

