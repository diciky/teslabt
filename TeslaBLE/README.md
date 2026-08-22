# TeslaBLE — Tesla 蓝牙低延迟数据收发显示 App

基于 **Tesla 车辆真实 BLE 协议** 的 iOS 应用，实现手机与车辆之间的**低延迟数据发送 / 接收 / 实时显示**，支持本地车辆控制（锁车、解锁、鸣笛、闪灯等），无需云端 API。

## 功能特性

- 🔍 **自动扫描并连接 Tesla 车辆**（BLE Central，使用真实 Tesla Service UUID）
- 🔐 **P-256 ECDH 密钥协商 + AES-GCM 加密 + HMAC 认证**
- 🎛️ **车辆控制**：锁车、解锁、鸣笛、闪灯、状态查询
- 📊 **实时显示**：车速、电量、里程、温度等遥测数据的实时展示
- ⚡ **传输统计**：平均/最近延迟、吞吐率、收发包数、丢包率
- 🎯 **低延迟模式开关**：可切换不同收发策略
- 📱 **SwiftUI + CoreBluetooth + CryptoKit**，原生实现，运行于 iOS 15+（含 iOS 16.6.1 及以下版本）

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
│  BLEService (Central 管理 / 会话加密 / 收发)      │
│  TeslaProtocol (UUID / 帧协议 / 消息构建)         │
│  TeslaBLEKeyManager (Keychain 密钥管理)           │
│  TeslaBLESessionCrypto (ECDH / AES-GCM / HMAC)   │
├─────────────────────────────────────────────────┤
│                 Model 层                         │
│  TelemetryModel (样本 / 状态 / 统计 / 命令)       │
└─────────────────────────────────────────────────┘
```

## Tesla BLE 协议

### BLE 标识

| 项目 | UUID |
|------|------|
| 车辆服务 | `00000211-b2d1-43f0-9b88-960cebf8b91e` |
| 写特征 | `00000212-b2d1-43f0-9b88-960cebf8b91e` |
| 指示特征 | `00000213-b2d1-43f0-9b88-960cebf8b91e` |
| 蓝牙名称 | `Tesla + VIN后6位` 或基于 VIN SHA1 的格式 |

### 安全协议

1. **密钥生成**：NIST P-256（secp256r1）曲线生成密钥对
2. **白名单（配对）**：公钥添加到车辆（需车内确认）
3. **会话协商**：ECDH 交换 + HKDF-SHA256 派生会话密钥
4. **加密通信**：AES-GCM 加密消息 + HMAC-SHA256 认证

### 域

- **VCSEC**（车辆安全）：锁/解锁、后备箱、钥匙管理
- **Infotainment**（信息娱乐）：充电、空调、媒体、车辆数据查询

## 快速开始

### 前置条件

- 车辆支持 Phone Key（2021+ 大部分车型）
- iPhone 支持 BLE（iPhone 8+ / iOS 15+）
- 首次使用需在车辆中控屏确认白名单配对

### 使用步骤

1. 打开 App，点击 **扫描连接**
2. 连接成功后，App 会自动发起密钥协商
3. 若未认证，点击 **开始配对**，在车辆中控屏确认
4. 认证后即可使用锁车/解锁/鸣笛/闪灯等控制功能

### 系统兼容性

工程 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`，即生成的 `.ipa` **支持 iOS 15.0 及以上全部版本**（包含 iOS 16.6.1 及以下版本）。代码未使用任何 iOS 17+ 独占 API，可放心在 iOS 16.6.1 设备上安装运行。

### 构建 .ipa

iOS 的 `.ipa` 只能在 **macOS + Xcode** 上编译并签名，支持两种方式：

**方式一：本机 macOS 手动构建**

```bash
# 在 macOS 上（需已配置 Apple 签名证书与描述文件）
xcodebuild -project TeslaBLE.xcodeproj \
  -scheme TeslaBLE \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/TeslaBLE.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/TeslaBLE.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

# 产物位于 build/export/TeslaBLE.ipa
```

**方式二：CNB 云原生构建（自托管 macOS Runner）**

仓库已内置 `.cnb.yml` 流水线，接入一台 macOS 自托管节点后，`push` 到 `main` 即可自动生成 `.ipa`：

- 自托管节点标签需包含 `mac`、`arm64`（Apple Silicon）或 `xcode`
- 节点需预装 Xcode，并配置好开发签名证书/描述文件
- 流水线执行 `xcodebuild archive` + `-exportArchive`，产物位于构建工作区 `build/export/TeslaBLE.ipa`

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
    │   └── TelemetryModel.swift   # 数据模型 / 状态 / 命令
    ├── Services/
    │   ├── BLEService.swift       # 蓝牙核心服务（连接/加密/收发）
    │   └── TeslaProtocol.swift    # 协议常量 / 密钥管理 / 加密 / 消息
    ├── ViewModels/
    │   └── DashboardViewModel.swift
    └── Views/
        ├── ContentView.swift
        └── DashboardView.swift
```

## 注意事项

- 需要车辆支持 Phone Key（大多数 2021+ 车型）
- 私钥安全存储在 iOS Keychain，丢失需重新配对
- BLE 距离有限（通常几米到十几米），适合车库/家用本地场景
- 老款车型（2021 年前的部分 S/X）可能不支持新协议
- 非官方实现可能因固件更新失效，使用风险自担

## 参考资源

- [Tesla Vehicle Command SDK](https://github.com/teslamotors/vehicle-command)
- [TeslaBT API 非官方文档](https://www.teslabtapi.com)
- [Tesla Protobufs](https://github.com/acvigue/TeslaProtobufs)
