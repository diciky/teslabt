# TeslaBLE — Tesla 蓝牙低延迟数据收发显示 App

基于 **Tesla 车辆 BLE（蓝牙低功耗）** 协议的 iOS 应用，实现手机与车辆之间的**低延迟数据发送 / 接收 / 实时显示**。

## 功能特性

- 🔍 **自动扫描并连接 Tesla 车辆**（BLE Central）
- 📡 **低延迟数据收发**：采用 GATT `Notify + Write` 通道，帧头校验 + 序列号 + CRC-8 实现低延迟确认与丢包检测
- 📊 **实时显示**：车速、电量、里程、温度等遥测数据的实时展示
- ⚡ **传输统计**：平均/最近延迟、吞吐率、收发包数、丢包率
- 🎛️ **低延迟模式开关**：可切换不同收发策略
- 📱 **SwiftUI + CoreBluetooth**，原生实现，运行于 iOS 15+

## 技术架构

```
┌─────────────────────────────────────────────────┐
│                      UI 层 (SwiftUI)            │
│  DashboardView / ContentView                     │
├─────────────────────────────────────────────────┤
│               ViewModel 层 (MVVM)                │
│  DashboardViewModel                               │
├─────────────────────────────────────────────────┤
│               Service 层 (CoreBluetooth)         │
│  BLEService (Central 管理 / 收发)                 │
│  TeslaProtocol (帧编解码 / CRC / 协议常量)         │
├─────────────────────────────────────────────────┤
│                 Model 层                         │
│  TelemetryModel (数据样本 / 状态 / 统计)           │
└─────────────────────────────────────────────────┘
```

## 低延迟设计要点

1. **Notify 实时订阅**：订阅特征的通知（`setNotifyValue`），车辆数据变更即刻推送到 App，无需轮询。
2. **单帧直发**：负载 ≤ MTU 时单帧发送，写入类型为 `.withResponse` 以获取低延迟 ACK。
3. **序列号 + CRC-8**：每个数据帧携带序列号与校验码，可检测丢包并测量往返延迟。
4. **大数据切分**：超过 MTU 时切分发送，避免阻塞，保证整体低延迟。

## 蓝牙协议

| 项目 | UUID / 值 |
|------|-----------|
| 车辆服务 | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |
| 数据特征 | `bef8d6c9-9c21-4c9e-b632-bd58c1009f9f` |
| 车辆状态特征 | `0x2A6E` |
| 电池电量特征 | `0x2A19` |

帧格式（8+ 字节）：

```
[magic(1)][len(1)][seq(2)][type(1)][payload(n)][crc(1)]
```

## 运行与打包

### 环境要求
- macOS + Xcode 15+
- 真机调试（BLE 需要真实设备）

### 构建 .ipa
```bash
# 在 macOS 上
xcodebuild -project TeslaBLE.xcodeproj \
  -scheme TeslaBLE \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/TeslaBLE.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/TeslaBLE.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

# 产物位于 build/export/*.ipa
```

### 安装
将生成的 `.ipa` 通过 Xcode / Apple Configurator / 第三方工具（如 `ios-deploy`）安装到已签名的设备上。

## 项目结构

```
TeslaBLE/
├── TeslaBLE.xcodeproj/       # Xcode 工程
└── TeslaBLE/
    ├── TeslaBLEApp.swift      # App 入口
    ├── Info.plist             # 权限（蓝牙）+ 后台模式
    ├── Models/
    │   └── TelemetryModel.swift
    ├── Services/
    │   ├── BLEService.swift    # 蓝牙核心服务
    │   └── TeslaProtocol.swift # 协议封装
    ├── ViewModels/
    │   └── DashboardViewModel.swift
    └── Views/
        ├── ContentView.swift
        └── DashboardView.swift
```

## 说明

> Tesla 官方车辆 BLE 协议包含加密握手与密钥协商。本工程提供了完整的可运行 BLE 收发架构、帧协议与 UI 骨架；生产对接真实车辆时，请结合 Tesla 官方 SDK / 车辆密钥进行适配。本代码可在模拟器之外的测试环境下配合 BLE 调试设备验证低延迟收发链路。

## License

MIT
