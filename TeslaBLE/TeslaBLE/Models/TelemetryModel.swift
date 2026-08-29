import Foundation
import CoreBluetooth

/// 一条实时数据样本（从车机 BLE 接收）
struct TelemetrySample: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    /// 数据来源通道
    let channel: String
    /// 原始数据载荷（十六进制）
    let rawPayload: String
    /// 解析出的数值
    let value: Double
    /// 单位
    let unit: String

    init(channel: String, rawPayload: String, value: Double, unit: String = "") {
        self.id = UUID()
        self.timestamp = Date()
        self.channel = channel
        self.rawPayload = rawPayload
        self.value = value
        self.unit = unit
    }
}

/// 蓝牙连接状态
enum BLEConnectionState: Equatable {
    case idle
    case scanning
    case discovering
    case connecting
    case connected
    case disconnected(String)
    case error(String)

    var label: String {
        switch self {
        case .idle: return "未连接"
        case .scanning: return "扫描中…"
        case .discovering: return "发现服务…"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .disconnected(let msg): return "已断开：\(msg)"
        case .error(let msg): return "错误：\(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// 设备识别信息（从车机 BLE 获取）
struct DeviceInfo {
    /// 固件版本
    var firmwareVersion: String = "未知"
    /// 车辆 VIN
    var vin: String = ""
    /// 是否已配对（TRUST）
    var isPaired: Bool = false
    /// 链路状态描述
    var linkState: String = "未连接"
    /// 车辆名称（BLE 广播名）
    var vehicleName: String = ""
    /// 车辆 BLE ID
    var vehicleID: String = ""
    /// 信号强度 RSSI
    var rssi: Int = 0
    /// 电池电量
    var batteryLevel: Int = 0
}

/// 车机遥测数据（实时展示）
struct VehicleTelemetry {
    /// 车速 km/h
    var speedKmh: Double = 0
    /// 电量百分比
    var batteryPercent: Int = 0
    /// 里程 km
    var odometerKm: Double = 0
    /// 车内温度 °C
    var insideTemp: Double = 0
    /// 车外温度 °C
    var outsideTemp: Double = 0
    /// 剩余续航 km
    var rangeKm: Double = 0
    /// 门锁状态
    var locked: Bool = false
    /// 充电状态
    var charging: Bool = false
    /// 空调状态
    var climateOn: Bool = false
    /// 哨兵模式
    var sentryMode: Bool = false
    /// 胎压（各轮胎 bar）
    var tirePressureFL: Double = 0
    var tirePressureFR: Double = 0
    var tirePressureRL: Double = 0
    var tirePressureRR: Double = 0
}

/// 一次数据收发统计
struct TransferStats {
    var totalBytesSent: Int = 0
    var totalBytesReceived: Int = 0
    var packetsSent: Int = 0
    var packetsReceived: Int = 0
    /// 最近一次接收延迟（毫秒）
    var lastLatencyMs: Double = 0
    /// 数据吞吐率（字节/秒）
    var throughputBytesPerSec: Double = 0
}

/// 车辆状态（从 BLE 解密响应解析，实时展示）
struct VehicleStatus {
    var speedKmh: Double = 0
    var batteryPercent: Int = 0
    var odometerKm: Double = 0
    var state: String = "unknown"
    var temperatureC: Double = 0
    var locked: Bool = false
    var chargePortOpen: Bool = false
    var charging: Bool = false
    var climateOn: Bool = false
    var sentryMode: Bool = false
    var rangeKm: Double = 0
    var insideTemp: Double = 0
    var outsideTemp: Double = 0
}
