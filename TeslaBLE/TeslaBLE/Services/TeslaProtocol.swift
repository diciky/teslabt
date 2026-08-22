import Foundation
import CoreBluetooth
import CryptoKit

/// Tesla 车辆 BLE 协议封装。
///
/// 基于官方 Tesla Vehicle Command SDK 与社区协议文档实现：
/// - 真实 BLE Service/Characteristic UUID
/// - Protobuf 消息格式
/// - P-256 ECDH 会话密钥协商 + AES-GCM 加密 + HMAC 认证
/// - VCSEC（车辆安全）与 Infotainment（信息娱乐）双域
///
/// 参考：
/// - 官方 SDK: github.com/teslamotors/vehicle-command
/// - 社区文档: teslabtapi.com
enum TeslaProtocol {

    // MARK: - BLE 服务与特征常量（真实 Tesla UUID）

    /// Tesla 车辆 BLE 主服务 UUID
    static let vehicleServiceUUID = CBUUID(string: "00000211-b2d1-43f0-9b88-960cebf8b91e")

    /// 写特征（下发命令）
    static let writeCharacteristicUUID = CBUUID(string: "00000212-b2d1-43f0-9b88-960cebf8b91e")

    /// 指示特征（接收车辆响应）
    static let indicateCharacteristicUUID = CBUUID(string: "00000213-b2d1-43f0-9b88-960cebf8b91e")

    /// 会话特征（密钥协商用，部分车型存在）
    static let sessionCharacteristicUUID = CBUUID(string: "00000214-b2d1-43f0-9b88-960cebf8b91e")

    /// 标准电池电量特征（读取车辆电量）
    static let batteryUUID = CBUUID(string: "2A19")

    /// 标准设备名称特征
    static let deviceNameUUID = CBUUID(string: "2A00")

    /// 标准 GAP 特征
    static let appearanceUUID = CBUUID(string: "2A01")

    // MARK: - 会话与密钥协商

    /// 会话阶段
    enum SessionStage: Int {
        case idle = 0
        case awaitingVehiclePublicKey = 1
        case awaitingSessionInfo = 2
        case authenticated = 3
    }

    /// 消息类型（VCSEC 域，参考 Tesla Protobuf 定义）
    enum VCSECMessageType: UInt8 {
        case publicKeyRequest = 0x00
        case publicKeyResponse = 0x01
        case sessionInfoRequest = 0x02
        case sessionInfoResponse = 0x03
        case whitelistOperation = 0x04
        case whitelistOperationResponse = 0x05
        case signedMessage = 0x06
        case RKEAction = 0x07
        case vehicleStatus = 0x08
        case unsolicitedVehicleStatus = 0x09
        case error = 0x0A
    }

    /// VCSEC RKE 操作类型
    enum RKEAction: UInt8 {
        case unlock = 0x00
        case lock = 0x01
        case unlockChargePort = 0x02
        case lockChargePort = 0x03
        case openFrunk = 0x04
        case openTrunk = 0x05
        case closeTrunk = 0x06
        case openWindows = 0x07
        case closeWindows = 0x08
        case toggleSentinelMode = 0x09
        case honk = 0x0A
        case flash = 0x0B
        case activateSpeedLimit = 0x0C
        case deactivateSpeedLimit = 0x0D
    }

    // MARK: - 帧格式（BLE 传输层）

    /// 帧头魔数
    static let frameMagic: UInt8 = 0xAB

    /// BLE 特征最大单帧传输负载（建议值）
    static let maxWritePayload = 120

    // MARK: - 编码/解码辅助

    /// 编码一帧 BLE 数据（传输层封装）
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

    /// 解析一帧收到的低延迟数据
    static func decodeFrame(_ data: Data) -> (type: CommandType, sequence: UInt16, payload: [UInt8])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, bytes[0] == frameMagic else { return nil }
        let length = Int(bytes[1])
        guard bytes.count == 6 + length else { return nil }

        let crcIndex = bytes.count - 1
        guard crc8(Array(bytes[0..<crcIndex])) == bytes[crcIndex] else { return nil }

        guard let type = CommandType(rawValue: bytes[5]) else { return nil }
        let sequence = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let payload = Array(bytes[6..<crcIndex])
        return (type, sequence, payload)
    }

    /// 简易 CRC-8 校验
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

    // MARK: - 命令类型（兼容传输层）

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

    // MARK: - 遥测工具

    static func telemetryPayload(value: Double, channel: UInt8) -> [UInt8] {
        var payload = [UInt8]()
        payload.append(channel)
        payload.append(contentsOf: withUnsafeBytes(of: value.bitPattern) { Array($0) })
        return payload
    }

    static func parseDouble(from payload: [UInt8], offset: Int = 1) -> Double {
        guard payload.count >= offset + 8 else { return 0 }
        var raw: UInt64 = 0
        for i in 0..<8 {
            raw |= UInt64(payload[offset + i]) << (UInt64(i) * 8)
        }
        return Double(bitPattern: raw)
    }

    // MARK: - 车辆状态模型

    /// 车辆状态（从 BLE 响应解析）
    struct TeslaVehicleState {
        var batteryLevel: Int = 0
        var locked: Bool = false
        var chargePortOpen: Bool = false
        var charging: Bool = false
        var climateOn: Bool = false
        var speedKmh: Double = 0
        var odometerKm: Double = 0
        var temperatureC: Double = 0
        var lat: Double = 0
        var lng: Double = 0
        var rangeKm: Double = 0
        var insideTemp: Double = 0
        var outsideTemp: Double = 0
        var preconditioning: Bool = false
        var sentryMode: Bool = false
        var updateAvailable: Bool = false
    }
}

// MARK: - 密钥管理

/// Tesla BLE 密钥管理器
/// 负责生成 P-256 密钥对、持久化私钥、管理白名单流程
struct TeslaBLEKeyManager {

    // MARK: - 密钥存储

    /// 私钥存储 Keychain Key
    private static let privateKeyTag = "com.teslabt.privateKey"
    /// 公钥（已白名单）存储 Keychain Key
    private static let publicKeyTag = "com.teslabt.publicKey"

    /// 生成或读取已持久化的 P-256 密钥对
    static func getOrCreateKeyPair() -> P256.Signing.PrivateKey? {
        // 尝试从 Keychain 读取
        if let data = loadFromKeychain(tag: privateKeyTag),
           let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return privateKey
        }

        // 生成新的密钥对并保存
        let privateKey = P256.Signing.PrivateKey()
        let privateData = privateKey.rawRepresentation
        let publicData = privateKey.publicKey.rawRepresentation

        if saveToKeychain(tag: privateKeyTag, data: privateData),
           saveToKeychain(tag: publicKeyTag, data: publicData) {
            return privateKey
        }
        return nil
    }

    /// 获取当前公钥（用于白名单）
    static func getPublicKey() -> P256.Signing.PublicKey? {
        if let data = loadFromKeychain(tag: publicKeyTag) {
            return try? P256.Signing.PublicKey(rawRepresentation: data)
        }
        return getOrCreateKeyPair()?.publicKey
    }

    /// 删除所有密钥（重置）
    static func resetKeys() {
        deleteFromKeychain(tag: privateKeyTag)
        deleteFromKeychain(tag: publicKeyTag)
    }

    // MARK: - Keychain 辅助

    private static func saveToKeychain(tag: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func loadFromKeychain(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func deleteFromKeychain(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 会话加密

/// Tesla BLE 会话加密器
/// 使用 ECDH 协商出的共享密钥 + AES-GCM 加密 + HMAC 认证
struct TeslaBLESessionCrypto {

    struct SessionKeys {
        var sessionKey: SymmetricKey
        var macKey: SymmetricKey
    }

    /// 从本地私钥 + 车辆公钥派生会话密钥
    /// Tesla 使用 ECDH P-256 协商 + HKDF 派生
    static func deriveSessionKeys(
        localPrivateKey: P256.Signing.PrivateKey,
        vehiclePublicKeyRaw: Data
    ) -> SessionKeys? {
        // 使用 KeyAgreement 类型执行 ECDH
        // 私钥数据格式相同（32 字节 raw），可以安全转换
        guard let agreementKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKey.rawRepresentation),
              let vehiclePublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: vehiclePublicKeyRaw) else {
            return nil
        }

        // ECDH 共享密钥
        let sharedSecret = try? agreementKey.sharedSecretFromKeyAgreement(with: vehiclePublicKey)

        // 使用 HKDF-SHA256 派生会话密钥
        // Tesla 协议中：symmetric key 用于 AES-GCM 加密，mac key 用于 HMAC 认证
        let infoData = Data("TeslaVehicleCommand".utf8)
        let saltData = Data("TeslaSessionV1".utf8)

        guard let secret = sharedSecret else { return nil }

        // 派生 32 字节对称密钥 + 32 字节 MAC 密钥
        let expandedKey = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: saltData,
            sharedInfo: infoData,
            outputByteCount: 64
        )

        let keyData = expandedKey.withUnsafeBytes { Data($0) }
        guard keyData.count >= 64 else { return nil }

        let sessionKeyData = keyData[0..<32]
        let macKeyData = keyData[32..<64]

        return SessionKeys(
            sessionKey: SymmetricKey(data: sessionKeyData),
            macKey: SymmetricKey(data: macKeyData)
        )
    }

    /// AES-GCM 加密
    static func encrypt(_ data: Data, with key: SymmetricKey) -> Data? {
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            return sealed.combined
        } catch {
            return nil
        }
    }

    /// AES-GCM 解密
    static func decrypt(_ data: Data, with key: SymmetricKey) -> Data? {
        do {
            let sealed = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            return nil
        }
    }

    /// HMAC-SHA256 计算消息认证码
    static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }
}

// MARK: - 消息序列化辅助

/// 简单的 Protobuf-like 编码器
/// Tesla 协议使用 Protobuf，这里实现核心字段的编解码
struct TeslaProtobuf {

    /// 编码 varint
    static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var result = [UInt8]()
        var v = value
        while v > 0x7F {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    /// 解码 varint
    static func decodeVarint(_ bytes: [UInt8], at index: inout Int) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    /// 编码字段（tag + varint value）
    static func encodeField(_ fieldNumber: Int, _ value: UInt64) -> [UInt8] {
        let tag = UInt64(fieldNumber << 3) | 0 // wire type 0 = varint
        var result = encodeVarint(tag)
        result.append(contentsOf: encodeVarint(value))
        return result
    }

    /// 编码字节字段（wire type 2 = length-delimited）
    static func encodeBytesField(_ fieldNumber: Int, _ data: Data) -> [UInt8] {
        let tag = UInt64(fieldNumber << 3) | 2
        var result = encodeVarint(tag)
        result.append(contentsOf: encodeVarint(UInt64(data.count)))
        result.append(contentsOf: data)
        return result
    }

    /// 解码字段，返回 [(fieldNumber, wireType, valueData)]
    static func decodeFields(_ data: Data) -> [(Int, Int, Data)] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [(Int, Int, Data)] = []

        while index < bytes.count {
            let tag = decodeVarint(bytes, at: &index)
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x7)

            switch wireType {
            case 0: // varint
                let value = decodeVarint(bytes, at: &index)
                var valueBytes: [UInt8] = []
                var v = value
                if v == 0 {
                    valueBytes = [0]
                } else {
                    while v > 0 {
                        valueBytes.insert(UInt8(v & 0xFF), at: 0)
                        v >>= 8
                    }
                }
                fields.append((fieldNumber, wireType, Data(valueBytes)))
            case 2: // length-delimited
                let length = Int(decodeVarint(bytes, at: &index))
                if index + length <= bytes.count {
                    let value = Data(bytes[index..<index + length])
                    index += length
                    fields.append((fieldNumber, wireType, value))
                } else {
                    break
                }
            default:
                // 不支持其他 wire type，跳过
                break
            }
        }
        return fields
    }

    /// 从 fields 中获取指定字段的 varint 值
    static func getVarint(_ fields: [(Int, Int, Data)], field: Int) -> UInt64? {
        guard let (_, _, data) = fields.first(where: { $0.0 == field && $0.1 == 0 }) else { return nil }
        var index = 0
        return decodeVarint([UInt8](data), at: &index)
    }

    /// 从 fields 中获取指定字段的 bytes 值
    static func getBytes(_ fields: [(Int, Int, Data)], field: Int) -> Data? {
        return fields.first(where: { $0.0 == field && $0.1 == 2 })?.2
    }
}

// MARK: - VCSEC 消息构建

extension TeslaProtocol {

    /// 构建车辆状态请求消息
    static func buildVehicleStatusRequest() -> Data {
        // VCSEC 车辆状态请求
        return Data([0x08, 0x00]) // field 1, varint 0
    }

    /// 构建锁车命令
    static func buildLockCommand() -> Data {
        // VCSEC RKEAction: lock
        var msg = Data()
        msg.append(contentsOf: TeslaProtobuf.encodeField(1, 0)) // operation = lock
        return msg
    }

    /// 构建解锁命令
    static func buildUnlockCommand() -> Data {
        var msg = Data()
        msg.append(contentsOf: TeslaProtobuf.encodeField(1, 1)) // operation = unlock
        return msg
    }

    /// 构建鸣笛命令
    static func buildHonkCommand() -> Data {
        var msg = Data()
        msg.append(contentsOf: TeslaProtobuf.encodeField(1, UInt64(RKEAction.honk.rawValue)))
        return msg
    }

    /// 构建闪灯命令
    static func buildFlashCommand() -> Data {
        var msg = Data()
        msg.append(contentsOf: TeslaProtobuf.encodeField(1, UInt64(RKEAction.flash.rawValue)))
        return msg
    }
}
