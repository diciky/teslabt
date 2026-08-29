# XiaoZhiFlasher — 小智 WeMate 手机版刷机工具（iOS / tipa）

将原版 **WeMate 小智 Flasher**（Windows 桌面工具）复刻为 **iOS 手机版 App**，用 **tipa** 格式分发（TrollStore 直接安装，免签名）。

> 原版工具（`0829WeMate-小智-Flasher.exe`）通过 USB 串口 + esptool 对小智 WeMate（ESP32-S3 汽车表盘）进行刷机与配置。iOS 无 USB 主机能力，无法直接枚举 ESP32-S3 的 USB-Serial-JTAG，因此本 App 改用 **BLE 命令通道**实现设备连接、状态读取与配置命令下发，并在 App 内说明固件刷写的 iOS 限制。

## 功能

- 🔍 **BLE 扫描 / 连接**小智设备（默认 Nordic UART 服务，UUID 可自定义）
- 📊 **设备识别与状态**：固件版本、VIN、配对标志、BLE 链路状态
- 🚗 **身份配置**：写入 VIN（17 位，排除 I/O/Q）、私钥导入（KEYBEGIN/KEYEND）、TRUST 配对
- 🎛️ **显示配置**：背光亮度、屏幕方向（0/90/180/270）、表盘样式（复合/纯数字/全模拟/纯时间/纯功率）
- ⚡ **性能与功耗**：CPU 频率（240/160/80 MHz）、蓝牙发射功率（9/3/0/-3/-9 dBm）
- 🕒 **开机与定时**：开机自动演示、定时亮度（最多 8 段）
- 💾 **备份 / 恢复**：用户数据（VIN / 私钥 / 配对标志，`WMBK` 格式，兼容原版）
- 🖥️ **通信日志**：实时查看收发命令

## 命令协议

与 PC 版 `device.py` 一致，通过文本命令下发（固件侧做 VIN 校验、CRC、NVS 落盘）：

| 功能 | 命令 |
|------|------|
| 读状态 | `STATUS` |
| 写 VIN | `VIN <17位VIN>` |
| 导入私钥 | `KEYBEGIN` / PEM 行 / `KEYEND` |
| 配对 | `TRUST` |
| 背光 | `BL <10-100>` |
| CPU | `CPU <240/160/80>` |
| 蓝牙功率 | `BLEPWR <9/3/0/-3/-9>` |
| 方向 | `ROT <0/90/180/270>` |
| 表盘样式 | `DIAL <0-4>` |
| 开机演示 | `DEMOBOOT <0/1>` |
| 定时亮度 | `BLSCHED <off 或 起点:亮度,...>` |

## iOS 刷写限制说明

iOS 无 USB 主机模式，无法像 PC 版那样通过 esptool 刷写 bootloader / partitions / firmware。若你的小智固件内置 **BLE OTA / 固件升级服务**，可通过对应升级通道刷写；本 App 当前提供配置、备份与状态管理能力。

## 打包 tipa

`tipa` 是 TrollStore 的安装包格式（`.app` 的 zip 归档）。在 macOS + Xcode 构建 `XiaoZhiFlasher.app` 后，将 `.app` 压缩为 `.zip` 并改后缀为 `.tipa` 即可：

```bash
xcodebuild -project XiaoZhiFlasher.xcodeproj \
  -scheme XiaoZhiFlasher \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build archive

# 找到产物 .app
APP=$(find build -name "*.app" -type d | head -1)
cd "$(dirname "$APP")"
zip -r XiaoZhiFlasher.tipa "$(basename "$APP")"
# 得到 XiaoZhiFlasher.tipa
```

> TrollStore 设备（iOS 14.0–18 支持范围内）直接安装 `.tipa` 即可，无需签名。

## 工程结构

```
XiaoZhiFlasher/
├── XiaoZhiFlasher.xcodeproj/
└── XiaoZhiFlasher/
    ├── XiaoZhiFlasherApp.swift      # App 入口
    ├── Info.plist                   # 蓝牙权限
    ├── Models/
    │   ├── DeviceModel.swift        # 设备状态 / 表盘样式 / 配置模型
    │   └── Backup.swift             # 备份（WMBK）打包与校验
    ├── Services/
    │   ├── BLEService.swift         # BLE 连接与命令通道
    │   └── XiaoZhiProtocol.swift    # 命令协议实现
    ├── ViewModels/
    │   └── FlasherViewModel.swift
    └── Views/
        ├── ContentView.swift        # 主导航
        ├── ConnectionView.swift     # 连接页
        ├── ConfigView.swift         # 配置页
        ├── BackupView.swift         # 备份/刷写页
        └── ConsoleView.swift        # 日志页
```
