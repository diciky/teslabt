import Foundation
import CoreBluetooth

/// 一条实时遥测数据样本（低延迟接收的原始数据点）
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

/// 一次数据收发统计
struct TransferStats {
    var totalBytesSent: Int = 0
    var totalBytesReceived: Int = 0
    var packetsSent: Int = 0
    var packetsReceived: Int = 0
    /// 最近一次往返延迟（毫秒）
    var lastLatencyMs: Double = 0
    /// 平均延迟（毫秒）
    var averageLatencyMs: Double = 0
    /// 丢包率（%）
    var packetLossRate: Double = 0
    /// 数据吞吐率（字节/秒）
    var throughputBytesPerSec: Double = 0
}

/// 车辆状态（从 BLE 解密响应解析）
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

/// 车辆控制命令类型
enum VehicleControlCommand: String, CaseIterable, Identifiable {
    case lock = "锁车"
    case unlock = "解锁"
    case honk = "鸣笛"
    case flash = "闪灯"
    case status = "状态查询"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .honk: return "bell.fill"
        case .flash: return "lightbulb.fill"
        case .status: return "car.fill"
        }
    }
}
