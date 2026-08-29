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
        case remoteDrive = 20
        case autoSecureVehicle = 29
        case wakeVehicle = 30
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
        deleteFromKeychain(tag: vinKeyTag)
    }

    // MARK: - VIN 存储

    /// VIN 存储 Keychain Key
    private static let vinKeyTag = "com.teslabt.vin"

    /// 保存 VIN 到 Keychain
    static func saveVIN(_ vin: String) {
        saveToKeychain(tag: vinKeyTag, data: Data(vin.utf8))
    }

    /// 从 Keychain 读取已保存的 VIN
    static func getSavedVIN() -> String? {
        guard let data = loadFromKeychain(tag: vinKeyTag) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 私钥导入

    /// 导入 P-256 私钥到 Keychain
    static func importPrivateKey(_ key: P256.Signing.PrivateKey) -> Bool {
        let privateData = key.rawRepresentation
        let publicData = key.publicKey.rawRepresentation
        if saveToKeychain(tag: privateKeyTag, data: privateData),
           saveToKeychain(tag: publicKeyTag, data: publicData) {
            return true
        }
        return false
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

// MARK: - 会话加密（符合官方协议）

/// Tesla BLE 会话加密器
/// 遵循官方 vehicle-command 协议：
/// - 会话密钥 `K = SHA1(BIG_ENDIAN(Sx, 32))[:16]`（128 位 AES-GCM 密钥）
/// - 命令使用 AES-GCM PERSONALIZED 签名（AAD = SHA256(Metadata)）
struct TeslaBLESessionCrypto {

    /// 会话状态（握手中记录的车辆时间/epoch/counter）
    struct SessionKeys {
        /// 128 位 AES-GCM 共享密钥 K
        var sessionKey: SymmetricKey

        /// 车辆 epoch（16 字节，随机生成于车辆启动时）
        var epoch: Data
        /// 车辆当前 counter（握手时返回）
        var counter: UInt32
        /// 车辆 clock_time（握手时返回）
        var clockTime: UInt32
        /// 本地时钟与车辆时钟的差值（车辆时间 - 本地时间）
        var clockOffset: TimeInterval = 0
    }

    /// 从本地私钥 + 车辆公钥派生 128 位会话密钥 K
    /// 官方定义：`S = ECDH(c, V)`；`K = SHA1(BIG_ENDIAN(Sx,32))[:16]`
    static func deriveSessionKey(
        localPrivateKey: P256.Signing.PrivateKey,
        vehiclePublicKeyRaw: Data
    ) -> SymmetricKey? {
        // 转换为 KeyAgreement 类型执行 ECDH
        guard let agreementKey = try? P256.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKey.rawRepresentation),
              let vehiclePublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: vehiclePublicKeyRaw) else {
            return nil
        }

        guard let sharedSecret = try? agreementKey.sharedSecretFromKeyAgreement(with: vehiclePublicKey) else {
            return nil
        }

        // 提取共享秘密的 x 坐标（32 字节大端）
        let secretBytes = sharedSecret.withUnsafeBytes { Data($0) }
        // sharedSecret 原始表示即为 x 坐标（32 字节大端）
        let sx = secretBytes

        // K = SHA1(Sx)[:16]
        let digest = Insecure.SHA1.hash(data: sx)
        let keyData = Data(digest.prefix(16))

        return SymmetricKey(data: keyData)
    }

    /// AES-GCM 加密（使用共享密钥 K，12 字节随机 nonce）
    /// - Parameters:
    ///   - plaintext: 待加密明文
    ///   - key: 128 位会话密钥 K
    ///   - aad: 关联认证数据（命令加密时为 SHA256(Metadata)）
    /// - Returns: (nonce, ciphertext + tag) 的合并数据
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) -> (nonce: Data, sealed: Data)? {
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
            return (nonce.withUnsafeBytes { Data($0) }, sealed.combined)
        } catch {
            return nil
        }
    }

    /// AES-GCM 解密（响应解密）
    static func open(_ combined: Data, key: SymmetricKey, nonce: Data, aad: Data) -> Data? {
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), combined: combined)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            return nil
        }
    }

    /// HMAC-SHA256
    static func hmac(_ data: Data, key: SymmetricKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    /// 派生 session info 认证密钥：`SESSION_INFO_KEY = HMAC-SHA256(K, "session info")`
    static func sessionInfoKey(from key: SymmetricKey) -> SymmetricKey {
        let derived = hmac(Data("session info".utf8), key: key)
        return SymmetricKey(data: derived)
    }

    /// 派生命令认证密钥：`K' = HMAC-SHA256(K, "authenticated command")`（HMAC 认证用）
    static func commandAuthKey(from key: SymmetricKey) -> SymmetricKey {
        let derived = hmac(Data("authenticated command".utf8), key: key)
        return SymmetricKey(data: derived)
    }

    /// 常数时间比较
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.index(a.startIndex, offsetBy: i)] ^ b[b.index(b.startIndex, offsetBy: i)]
        }
        return diff == 0
    }
}

// MARK: - Metadata 序列化（官方 TLV 编码）

/// 官方协议 Metadata 的 TLV 序列化器。
/// 每个字段用 `tag || length || value` 编码，整数为大端，按 tag 升序排列，以 0xFF 结尾。
/// 用于：
/// - 命令签名（AES-GCM 的 AAD = SHA256(Metadata)）
/// - session info 认证（HMAC 的输入）
/// - 响应解密（AES-GCM Response 的 AAD）
struct TeslaMetadataSerializer {

    /// Metadata tag（对应 Signatures.Tag）
    enum Tag: UInt8 {
        case signatureType  = 0
        case domain         = 1
        case personalization = 2  // VIN
        case epoch          = 3
        case expiresAt      = 4
        case counter        = 5
        case challenge      = 6
        case flags          = 7
        case requestHash    = 8
        case fault          = 9
        case end            = 255
    }

    /// 签名类型（对应 Signatures.SignatureType）
    enum SignatureType: UInt8 {
        case aesGcm              = 0
        case aesGcmPersonalized  = 5
        case hmac                = 6
        case hmacPersonalized    = 8
        case aesGcmResponse      = 9
    }

    /// 域名（对应 UniversalMessage.Domain）
    enum Domain: UInt8 {
        case broadcast        = 0
        case vehicleSecurity  = 2
        case infotainment     = 3
    }

    /// Flags（对应 UniversalMessage.Flags）
    struct Flags {
        static let userCommand       = 1 << 0  // FLAG_USER_COMMAND
        static let encryptResponse   = 1 << 1  // FLAG_ENCRYPT_RESPONSE
    }

    // MARK: - 编码单个 TLV

    /// 编码一个字节值
    static func tlv(_ tag: Tag, _ value: UInt8) -> [UInt8] {
        [tag.rawValue, 1, value]
    }

    /// 编码一个 4 字节大端整数（如 expires_at, counter）
    static func tlv(_ tag: Tag, uint32 value: UInt32) -> [UInt8] {
        var result = [tag.rawValue, 4]
        result.append(UInt8((value >> 24) & 0xFF))
        result.append(UInt8((value >> 16) & 0xFF))
        result.append(UInt8((value >> 8) & 0xFF))
        result.append(UInt8(value & 0xFF))
        return result
    }

    /// 编码一个字节串（长度 < 256）
    static func tlv(_ tag: Tag, bytes: Data) -> [UInt8] {
        var result = [tag.rawValue, UInt8(bytes.count)]
        result.append(contentsOf: bytes)
        return result
    }

    // MARK: - 命令签名 Metadata

    /// 构建命令签名（AES-GCM PERSONALIZED）所需的 Metadata 字符串。
    /// 包含：签名类型、域、VIN、epoch、过期时间、counter、flags（若非 0）。
    static func commandMetadata(
        signatureType: SignatureType,
        domain: Domain,
        vin: String,
        epoch: Data,
        expiresAt: UInt32,
        counter: UInt32,
        flags: UInt32
    ) -> Data {
        var result = [UInt8]()
        result.append(contentsOf: tlv(.signatureType, signatureType.rawValue))
        result.append(contentsOf: tlv(.domain, domain.rawValue))
        result.append(contentsOf: tlv(.personalization, bytes: Data(vin.utf8)))
        result.append(contentsOf: tlv(.epoch, bytes: epoch))
        result.append(contentsOf: tlv(.expiresAt, uint32: expiresAt))
        result.append(contentsOf: tlv(.counter, uint32: counter))
        if flags != 0 {
            result.append(contentsOf: tlv(.flags, uint32: flags))
        }
        result.append(Tag.end.rawValue)
        return Data(result)
    }

    /// 构建 session info 认证 Metadata。
    /// 包含：签名类型(HMAC)、VIN、challenge（握手请求的 uuid）。
    static func sessionInfoMetadata(vin: String, challenge: Data) -> Data {
        var result = [UInt8]()
        result.append(contentsOf: tlv(.signatureType, SignatureType.hmac.rawValue))
        result.append(contentsOf: tlv(.personalization, bytes: Data(vin.utf8)))
        result.append(contentsOf: tlv(.challenge, bytes: challenge))
        result.append(Tag.end.rawValue)
        return Data(result)
    }

    /// 构建响应解密 Metadata（AES-GCM RESPONSE）。
    /// 包含：签名类型(AES_GCM_RESPONSE)、域、VIN、counter、flags、request_hash、fault。
    static func responseMetadata(
        domain: Domain,
        vin: String,
        counter: UInt32,
        flags: UInt32,
        requestHash: Data,
        fault: UInt32 = 0
    ) -> Data {
        var result = [UInt8]()
        result.append(contentsOf: tlv(.signatureType, SignatureType.aesGcmResponse.rawValue))
        result.append(contentsOf: tlv(.domain, domain.rawValue))
        result.append(contentsOf: tlv(.personalization, bytes: Data(vin.utf8)))
        result.append(contentsOf: tlv(.counter, uint32: counter))
        result.append(contentsOf: tlv(.flags, uint32: flags))  // 响应中始终包含 flags
        result.append(contentsOf: tlv(.requestHash, bytes: requestHash))
        if fault != 0 {
            result.append(contentsOf: tlv(.fault, uint32: fault))
        }
        result.append(Tag.end.rawValue)
        return Data(result)
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

    /// 编码字段（tag + varint value，wire type 0）
    static func encodeField(_ fieldNumber: Int, _ value: UInt64) -> [UInt8] {
        let tag = UInt64(fieldNumber << 3) | 0 // wire type 0 = varint
        var result = encodeVarint(tag)
        result.append(contentsOf: encodeVarint(value))
        return result
    }

    /// 编码字段（tag + fixed32 value，wire type 5）
    static func encodeFixed32Field(_ fieldNumber: Int, _ value: UInt32) -> [UInt8] {
        let tag = UInt64(fieldNumber << 3) | 5 // wire type 5 = fixed32（小端）
        var result = encodeVarint(tag)
        result.append(UInt8(value & 0xFF))
        result.append(UInt8((value >> 8) & 0xFF))
        result.append(UInt8((value >> 16) & 0xFF))
        result.append(UInt8((value >> 24) & 0xFF))
        return result
    }

    /// 编码字段（tag + 内嵌消息，wire type 2）
    static func encodeMessageField(_ fieldNumber: Int, _ message: Data) -> [UInt8] {
        encodeBytesField(fieldNumber, message)
    }

    /// 编码字节字段（wire type 2 = length-delimited）
    static func encodeBytesField(_ fieldNumber: Int, _ data: Data) -> [UInt8] {
        let tag = UInt64(fieldNumber << 3) | 2
        var result = encodeVarint(tag)
        result.append(contentsOf: encodeVarint(UInt64(data.count)))
        result.append(contentsOf: data)
        return result
    }

    /// 编码 oneof 枚举（wire type 0）
    static func encodeEnumField(_ fieldNumber: Int, _ value: UInt64) -> [UInt8] {
        encodeField(fieldNumber, value)
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
            case 5: // fixed32
                if index + 4 <= bytes.count {
                    let value = Data(bytes[index..<index + 4])
                    index += 4
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

// MARK: - VCSEC 消息构建（符合官方 protobuf）

extension TeslaProtocol {

    // MARK: VCSEC UnsignedMessage 载荷

    /// 构建 VCSEC.UnsignedMessage 车辆状态请求
    /// `UnsignedMessage { InformationRequest { informationRequestType: GET_STATUS } }`
    static func buildVehicleStatusRequest() -> Data {
        // InformationRequest: field1(informationRequestType)=0 → [0x08, 0x00]
        let infoReq = Data([0x08, 0x00])
        // UnsignedMessage: field1(InformationRequest 消息) → 0x0A 0x02 ...
        return Data(TeslaProtobuf.encodeMessageField(1, infoReq))
    }

    /// 构建 VCSEC.UnsignedMessage 车辆信息请求
    /// 用于获取车机固件版本等设备信息
    static func buildVehicleInfoRequest() -> Data {
        // InformationRequest: field1(informationRequestType)=1 (GET_VEHICLE_INFO) → [0x08, 0x01]
        let infoReq = Data([0x08, 0x01])
        // UnsignedMessage: field1(InformationRequest 消息)
        return Data(TeslaProtobuf.encodeMessageField(1, infoReq))
    }

    /// 构建 VCSEC.UnsignedMessage 锁车命令
    /// `UnsignedMessage { RKEAction: RKE_ACTION_LOCK }`
    static func buildLockCommand() -> Data {
        // UnsignedMessage: field2(RKEAction varint) = LOCK(1)
        return Data(TeslaProtobuf.encodeEnumField(2, UInt64(RKEAction.lock.rawValue)))
    }

    /// 构建 VCSEC.UnsignedMessage 解锁命令
    /// `UnsignedMessage { RKEAction: RKE_ACTION_UNLOCK }`
    static func buildUnlockCommand() -> Data {
        // UnsignedMessage: field2(RKEAction varint) = UNLOCK(0)
        return Data(TeslaProtobuf.encodeEnumField(2, UInt64(RKEAction.unlock.rawValue)))
    }

    /// 构建 VCSEC.UnsignedMessage 鸣笛命令（honk 需要先 RKEAction remoteDrive 唤醒）
    static func buildHonkCommand() -> Data {
        // 简化为发送 RKEAction WAKE_VEHICLE(30) 以唤醒并保持
        return Data(TeslaProtobuf.encodeEnumField(2, UInt64(RKEAction.wakeVehicle.rawValue)))
    }

    /// 构建 VCSEC.UnsignedMessage 闪灯命令
    static func buildFlashCommand() -> Data {
        // VCSEC 无独立 flash 操作，flash 通过 Infotainment 域；此处以 wakeVehicle 近似
        return Data(TeslaProtobuf.encodeEnumField(2, UInt64(RKEAction.wakeVehicle.rawValue)))
    }

    /// 构建 VCSEC.UnsignedMessage 白名单添加密钥操作
    /// `WhitelistOperation { addPublicKeyToWhitelist { PublicKeyRaw } }`（UnsignedMessage field16）
    static func buildWhitelistAddKey(publicKey: Data) -> Data {
        // PublicKey: field1(PublicKeyRaw 字节)
        let pubKey = Data(TeslaProtobuf.encodeBytesField(1, publicKey))
        // WhitelistOperation: field1(addPublicKeyToWhitelist 消息)
        let whitelistOp = Data(TeslaProtobuf.encodeMessageField(1, pubKey))
        // UnsignedMessage: field16(WhitelistOperation 消息)
        return Data(TeslaProtobuf.encodeMessageField(16, whitelistOp))
    }

    /// 从 BLE 广播名称提取车辆 ID（`S+ID+C` 格式，ID 为 VIN 的 SHA1 前 8 字节 hex）
    static func vehicleID(fromLocalName name: String) -> String? {
        guard name.hasPrefix("S"), name.hasSuffix("C") else { return nil }
        let start = name.index(name.startIndex, offsetBy: 1)
        let end = name.index(name.endIndex, offsetBy: -1)
        guard start < end else { return nil }
        return String(name[start..<end])
    }

    // MARK: RoutableMessage 编解码（官方 BLE 消息格式）

    /// 构建并签名一条发送给指定域的 RoutableMessage（AES-GCM PERSONALIZED）。
    ///
    /// - Parameters:
    ///   - payload: 应用层明文（VCSEC.UnsignedMessage 或 CarServer.Action 的 protobuf）
    ///   - domain: 目标域（VCSEC 或 Infotainment）
    ///   - vin: 车辆识别号（用于个性化签名）
    ///   - session: 当前会话状态
    ///   - clientPublicKey: 客户端公钥 ENCODE_PUBLIC(C)
    ///   - expiryWindow: 命令有效期（秒），默认 30 秒
    /// - Returns: (完整 RoutableMessage, requestHash, uuid, 使用的 counter)
    static func buildSignedRoutableMessage(
        payload: Data,
        domain: TeslaMetadataSerializer.Domain,
        vin: String,
        session: TeslaBLESessionCrypto.SessionKeys,
        clientPublicKey: Data,
        expiryWindow: UInt32 = 30
    ) -> (message: Data, requestHash: Data, uuid: Data, counter: UInt32, nonce: Data, tag: Data)? {
        let flags = UInt32(TeslaMetadataSerializer.Flags.encryptResponse)
        let counter = session.counter &+ 1

        // 过期时间 = 车辆时钟当前时间 + 窗口
        let nowVehicle = session.clockTime + UInt32(max(0, session.clockOffset))
        let expiresAt = nowVehicle + expiryWindow

        // 构建命令 Metadata（签名类型=AES_GCM_PERSONALIZED）
        let metadata = TeslaMetadataSerializer.commandMetadata(
            signatureType: .aesGcmPersonalized,
            domain: domain,
            vin: vin,
            epoch: session.epoch,
            expiresAt: expiresAt,
            counter: counter,
            flags: flags
        )

        // AES-GCM 加密：AAD = SHA256(Metadata)
        let aad = Data(SHA256.hash(data: metadata))
        guard let sealed = TeslaBLESessionCrypto.seal(payload, key: session.sessionKey, aad: aad) else {
            return nil
        }
        // sealed = ciphertext + tag（后 16 字节为 tag）
        let ciphertext = sealed.sealed.dropLast(16)
        let tag = sealed.sealed.suffix(16)

        // 随机 uuid（<=16 字节）与 routing address
        let uuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let routingAddress = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        // 构建 RoutableMessage
        let rm = buildRoutableMessage(
            toDomain: domain,
            routingAddress: routingAddress,
            payload: Data(ciphertext),
            flags: flags,
            uuid: uuid,
            signerPublicKey: clientPublicKey,
            signatureType: .aesGcmPersonalized,
            epoch: session.epoch,
            nonce: sealed.nonce,
            counter: counter,
            expiresAt: expiresAt,
            tag: Data(tag)
        )

        // requestHash = [签名类型字节] + tag（VCSEC 截断为 17 字节）
        var requestHash = Data([TeslaMetadataSerializer.SignatureType.aesGcmPersonalized.rawValue])
        requestHash.append(Data(tag))
        if domain == .vehicleSecurity {
            requestHash = requestHash.prefix(17)
        }

        return (rm, requestHash, uuid, counter, sealed.nonce, Data(tag))
    }

    /// 构建会话信息请求（handshake）RoutableMessage。
    /// `session_info_request.public_key = ENCODE_PUBLIC(C)`
    static func buildSessionInfoRequest(clientPublicKey: Data) -> (message: Data, uuid: Data) {
        let uuid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let routingAddress = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        // SessionInfoRequest: field1(public_key 字节) = ENCODE_PUBLIC(C)
        let sessionInfoRequest = Data(TeslaProtobuf.encodeBytesField(1, clientPublicKey))

        var rm = Data()
        // to_destination { domain } (field6, 消息)
        let toDest = Data(TeslaProtobuf.encodeEnumField(1, UInt64(TeslaMetadataSerializer.Domain.vehicleSecurity.rawValue)))
        rm.append(contentsOf: TeslaProtobuf.encodeMessageField(6, toDest))
        // from_destination { routing_address } (field7, 消息)
        let fromDest = Data(TeslaProtobuf.encodeBytesField(2, routingAddress))
        rm.append(contentsOf: TeslaProtobuf.encodeMessageField(7, fromDest))
        // session_info_request (field14)
        rm.append(contentsOf: TeslaProtobuf.encodeBytesField(14, sessionInfoRequest))
        // uuid (field51)
        rm.append(contentsOf: TeslaProtobuf.encodeBytesField(51, uuid))

        return (rm, uuid)
    }

    /// 解析握手响应，提取车辆公钥、epoch、counter、clock_time 与 session_info_tag。
    static func parseSessionInfoResponse(_ data: Data) -> (
        vehiclePublicKey: Data,
        epoch: Data,
        counter: UInt32,
        clockTime: UInt32,
        sessionInfoTag: Data
    )? {
        let fields = TeslaProtobuf.decodeFields(data)

        // session_info (field15)
        guard let sessionInfoData = TeslaProtobuf.getBytes(fields, field: 15) else { return nil }
        let sessionFields = TeslaProtobuf.decodeFields(sessionInfoData)

        guard let publicKey = TeslaProtobuf.getBytes(sessionFields, field: 2) else { return nil }
        guard let epoch = TeslaProtobuf.getBytes(sessionFields, field: 3) else { return nil }
        let counter = UInt32(TeslaProtobuf.getVarint(sessionFields, field: 1) ?? 0)
        let clockTime = decodeFixed32(from: TeslaProtobuf.getBytes(sessionFields, field: 4))

        // signature_data (field13) → session_info_tag (field6)
        var sessionInfoTag = Data()
        if let sigData = TeslaProtobuf.getBytes(fields, field: 13) {
            let sigFields = TeslaProtobuf.decodeFields(sigData)
            if let tag = TeslaProtobuf.getBytes(sigFields, field: 6) {
                sessionInfoTag = tag
            }
        }

        return (publicKey, epoch, counter, clockTime, sessionInfoTag)
    }

    /// 解析 4 字节 fixed32（小端）为 UInt32
    static func decodeFixed32(from data: Data?) -> UInt32 {
        guard let data = data, data.count >= 4 else { return 0 }
        let bytes = [UInt8](data)
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    /// 构建完整 RoutableMessage（通用）
    private static func buildRoutableMessage(
        toDomain: TeslaMetadataSerializer.Domain,
        routingAddress: Data,
        payload: Data,
        flags: UInt32,
        uuid: Data,
        signerPublicKey: Data,
        signatureType: TeslaMetadataSerializer.SignatureType,
        epoch: Data,
        nonce: Data,
        counter: UInt32,
        expiresAt: UInt32,
        tag: Data
    ) -> Data {
        var rm = Data()

        // to_destination { domain } (field6)
        let toDest = Data(TeslaProtobuf.encodeEnumField(1, UInt64(toDomain.rawValue)))
        rm.append(contentsOf: TeslaProtobuf.encodeMessageField(6, toDest))
        // from_destination { routing_address } (field7)
        let fromDest = Data(TeslaProtobuf.encodeBytesField(2, routingAddress))
        rm.append(contentsOf: TeslaProtobuf.encodeMessageField(7, fromDest))
        // protobuf_message_as_bytes (field10) = 密文
        rm.append(contentsOf: TeslaProtobuf.encodeBytesField(10, payload))

        // signature_data (field13)
        var sigData = Data()
        // signer_identity { public_key } (field1)
        let signerIdentity = Data(TeslaProtobuf.encodeBytesField(1, signerPublicKey))
        sigData.append(contentsOf: TeslaProtobuf.encodeMessageField(1, signerIdentity))
        // AES_GCM_Personalized_data (field5)
        var sigAes = Data()
        sigAes.append(contentsOf: TeslaProtobuf.encodeBytesField(1, epoch))
        sigAes.append(contentsOf: TeslaProtobuf.encodeBytesField(2, nonce))
        sigAes.append(contentsOf: TeslaProtobuf.encodeField(3, UInt64(counter)))
        sigAes.append(contentsOf: TeslaProtobuf.encodeFixed32Field(4, expiresAt))
        sigAes.append(contentsOf: TeslaProtobuf.encodeBytesField(5, tag))
        sigData.append(contentsOf: TeslaProtobuf.encodeMessageField(5, sigAes))
        rm.append(contentsOf: TeslaProtobuf.encodeMessageField(13, sigData))

        // flags (field52)
        if flags != 0 {
            rm.append(contentsOf: TeslaProtobuf.encodeField(52, UInt64(flags)))
        }
        // uuid (field51)
        rm.append(contentsOf: TeslaProtobuf.encodeBytesField(51, uuid))

        return rm
    }
}
