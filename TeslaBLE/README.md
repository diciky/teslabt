# TeslaBLE — 特斯拉车机蓝牙数据接收 App

基于 **Tesla 官方 Vehicle Command 协议（`github.com/teslamotors/vehicle-command`）** 的 iOS 应用，**只做一件事**：通过蓝牙接收车机数据并在手机上实时展示。

## 功能

### 📊 设备识别
- 固件版本：实时获取车机固件信息
- VIN：显示当前绑定的车辆识别号
- 配对标志：TRUST 配对状态（✅ 已配对 / ❌ 未配对）
- 链路状态：连接状态实时显示（扫描中 / 连接中 / 密钥协商中 / 已认证 / 已断开）

### 🚗 身份配置
- **VIN 写入**：17 位字符，自动排除 I/O/Q，格式校验后保存到 Keychain
- **私钥导入**：支持 PEM 格式（KEYBEGIN/KEYEND 包裹），解析后安全存储
- **TRUST 配对**：一键发起白名单操作，需在车内中控屏确认

### 🎛️ 显示
- **横向布局**：适配手机横屏，大数字展示车速、电量、里程
- **实时数据流**：车机推送的原始数据实时刷新显示

## 技术架构

```
┌──────────────────────────────────────────┐
│              UI 层 (SwiftUI)             │
│  DashboardView / IdentityConfigView       │
├──────────────────────────────────────────┤
│            ViewModel 层 (MVVM)           │
│  DashboardViewModel                       │
├──────────────────────────────────────────┤
│            Service 层 (CoreBluetooth)    │
│  BLEService (连接/加密/接收/解析)          │
│  TeslaProtocol (协议/密钥/消息)            │
├──────────────────────────────────────────┤
│              Model 层                    │
│  TelemetryModel (设备/遥测/统计)          │
└──────────────────────────────────────────┘
```

## Tesla BLE 协议

### BLE 标识
- 车辆服务：`00000211-b2d1-43f0-9b88-960cebf8b91e`
- 写特征：`00000212-b2d1-43f0-9b88-960cebf8b91e`
- 指示特征：`00000213-b2d1-43f0-9b88-960cebf8b91e`
- 蓝牙名称：`S + <VIN的SHA1前8字节hex> + C`

### 安全协议
1. P-256 ECDH 密钥协商
2. 会话密钥 `K = SHA1(Sx)[:16]`
3. AES-GCM 命令签名 + HMAC 认证
4. BLE 传输：2 字节大端长度前缀 + RoutableMessage

## 构建

iOS 的 `.ipa` 只能在 macOS + Xcode 上编译，支持：
- 本机 `xcodebuild` 构建
- CNB 云原生构建（`.cnb.yml`）
- GitHub Actions 云构建（`.github/workflows/build-ipa.yml`）

## 项目结构

```
TeslaBLE/
├── TeslaBLE.xcodeproj/
└── TeslaBLE/
    ├── TeslaBLEApp.swift
    ├── Models/
    │   └── TelemetryModel.swift
    ├── Services/
    │   ├── BLEService.swift
    │   └── TeslaProtocol.swift
    ├── ViewModels/
    │   └── DashboardViewModel.swift
    └── Views/
        ├── ContentView.swift
        └── DashboardView.swift
```

## 注意事项
- 需要车辆支持 Phone Key（2021+ 大部分车型）
- 私钥安全存储在 iOS Keychain
- 非官方实现可能因固件更新失效，使用风险自担
