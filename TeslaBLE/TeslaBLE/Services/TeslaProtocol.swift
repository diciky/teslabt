import Foundation
import CoreBluetooth

/// Tesla 车辆 BLE 协议封装。
///
/// Tesla 车辆作为 BLE Peripheral 广播，手机 App 作为 Central 连接。
/// 本类封装了已知的 Tesla BLE 服务/特征常量、数据帧编码解码以及
/// 低延迟收发所依赖的消息格式。由于 Tesla 官方协议包含加密握手，
/// 生产环境请结合官方 SDK / 密钥协商使用；此处提供可扩展、可替换的骨架。
enum TeslaProtocol {

    // MARK: - BLE 服务与特征常量
    /// Tesla 车辆 BLE 主服务 UUID
    static let vehicleServiceUUID = CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")
    /// 数据交换特征（Notify + Write，用于低延迟实时收发）
    static let dataCharacteristicUUID = CBUUID(string: "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f")
    /// 车辆状态特征
    static let vehicleStatusUUID = CBUUID(string: "0x2A6E")
    /// 电池电量特征（标准 GATT 特征）
    static let batteryUUID = CBUUID(string: "0x2A19")

    // MARK: - 帧格式
    /// 帧头魔数，用于校验
    private static let frameMagic: UInt8 = 0xAB

    /// 命令类型
    enum CommandType: UInt8 {
        case ping = 0x01
        case status = 0x02
        case telemetry = 0x03
        case control = 0x04
        case pong = 0x81
        case statusResponse = 0x82
        case telemetryResponse = 0x83
        case controlResponse = 0x84
        case ack = 0x85
    }

    /// 编码一帧低延迟数据（写请求 / 下发控制）
    /// 帧结构：[magic(1)][len(1)][seq(2)][type(1)][payload(n)][crc(1)]
    static func encodeFrame(type: CommandType, sequence: UInt16, payload: [UInt8]) -> Data {
        var frame = [UInt8]()
        frame.append(frameMagic)
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(UInt8((sequence >> 8) & 0xFF))
        frame.append(UInt8(sequence & 0xFF))
        frame.append(type.rawValue)
        frame.append(contentsOf: payload)
        frame.append(crc8(frame))
        return Data(frame)
    }

    /// 解析一帧收到的低延迟数据，返回 (type, sequence, payload)
    static func decodeFrame(_ data: Data) -> (type: CommandType, sequence: UInt16, payload: [UInt8])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] == frameMagic else { return nil }
        let length = Int(bytes[1])
        // 帧结构：magic(1)+len(1)+seq(2)+type(1)+payload(n)+crc(1) = 6 + n
        guard bytes.count == 6 + length else { return nil }

        // 校验 CRC
        let crcIndex = bytes.count - 1
        guard crc8(Array(bytes[0..<crcIndex])) == bytes[crcIndex] else { return nil }

        guard let type = CommandType(rawValue: bytes[5]) else { return nil }
        let sequence = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let payload = Array(bytes[6..<crcIndex])
        return (type, sequence, payload)
    }

    /// 简易 CRC-8（校验帧完整性）
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    /// 将遥测数值打包成负载（用于发送）
    static func telemetryPayload(value: Double, channel: UInt8) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(channel)
        payload.append(contentsOf: withUnsafeBytes(of: value.bitPattern) { Array($0) })
        return payload
    }

    /// 从负载中解析出 Double（用于接收显示）
    static func parseDouble(from payload: [UInt8], offset: Int = 1) -> Double {
        guard payload.count >= offset + 8 else { return 0 }
        var raw: UInt64 = 0
        for i in 0..<8 {
            raw |= UInt64(payload[offset + i]) << (UInt64(i) * 8)
        }
        return Double(bitPattern: raw)
    }
}
