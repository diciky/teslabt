import Foundation

/// 小智 WeMate 设备状态
struct DeviceStatus: Identifiable {
    var id = UUID()
    var isConnected = false
    var isOurs = false            // 是否跑的是我们的小智固件
    var version: String?
    var vin: String?
    var paired = false            // 是否已进车辆白名单
    var linkState: Int?           // BLE 链路状态
    var chip: String?
    var mac: String?
    var flashSize: String?
    var features: String?
    var raw: String = ""
}

/// 表盘样式
enum DialStyle: Int, CaseIterable, Identifiable {
    case combo = 0    // 复合
    case digits = 1   // 纯数字
    case analog = 2   // 全模拟
    case clock = 3    // 纯时间
    case power = 4    // 纯功率

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .combo:   return "复合"
        case .digits:  return "纯数字"
        case .analog:  return "全模拟"
        case .clock:   return "纯时间"
        case .power:   return "纯功率"
        }
    }
}

/// 定时亮度段
struct BrightnessSlot: Identifiable, Equatable {
    var id = UUID()
    var startMinutes: Int   // 距 0 点分钟数
    var brightness: Int     // 10~100
}

/// 设备完整设置
struct DeviceSettings {
    var backlight: Int?        // BL 10~100
    var cpuMHz: Int?           // 240 / 160 / 80
    var blePowerDBm: Int?      // 9 / 3 / 0 / -3 / -9
    var rotation: Int?         // 0 / 90 / 180 / 270
    var dialStyle: DialStyle?
    var demoBoot: Bool?        // 开机演示
    var ringDigits: Bool?      // 纯数字表盘蓝圈
    var ringClock: Bool?       // 时钟表盘蓝圈
    var schedule: [BrightnessSlot]?
}
