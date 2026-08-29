import Foundation
import CoreBluetooth
import Combine
import CryptoKit

/// Tesla 车机 BLE 蓝牙服务
///
/// 职责：
/// 1. 扫描并连接 Tesla 车机
/// 2. 密钥协商（P-256 ECDH + AES-GCM）建立加密会话
/// 3. 接收车机实时数据（加密响应解密后解析）
/// 4. 设备识别信息收集（固件版本、VIN、配对标志、链路状态）
/// 5. 身份配置（写入 VIN、导入私钥、TRUST 配对）
final class BLEService: NSObject, ObservableObject {

    // MARK: - 对外状态发布
    @Published var state: BLEConnectionState = .idle
    @Published var receivedSamples: [TelemetrySample] = []
    @Published var stats = TransferStats()
    @Published var vehicleState = TeslaProtocol.TeslaVehicleState()
    @Published var sessionStage: TeslaProtocol.SessionStage = .idle
    @Published var isAuthenticated = false
    @Published var deviceInfo = DeviceInfo()

    /// 接收到的原始数据帧流（供 ViewModel 订阅）
    let frameSubject = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var indicateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var deviceNameCharacteristic: CBCharacteristic?

    // 会话密钥
    private var localPrivateKey: P256.Signing.PrivateKey?
    private var sessionKeys: TeslaBLESessionCrypto.SessionKeys?
    private var vehiclePublicKey: Data?

    /// 车辆 VIN（用于命令个性化签名）
    var vin: String = "" {
        didSet {
            if !vin.isEmpty {
                deviceInfo.vin = vin
            }
        }
    }

    /// 握手请求的 uuid（用于 session info 认证 challenge）
    private var handshakeUUID: Data?
    /// 最近一次发送命令的 requestHash（用于响应解密）
    private var pendingRequestHash: Data?
    /// 最近一次发送命令的 domain
    private var pendingDomain: TeslaMetadataSerializer.Domain?

    /// BLE 传输层：接收缓冲区
    private var receiveBuffer = Data()

    // 消息序号
    private var messageCounter: UInt32 = 0

    /// 车辆名称（扫描过滤用）
    private var targetVehicleName: String?

    private let maxPayloadBytes = 120

    // MARK: - 初始化
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadKeys()
        loadSavedVIN()
    }

    // MARK: - 对外接口

    /// 开始扫描 Tesla 车机
    func startScanning(vehicleName: String? = nil) {
        targetVehicleName = vehicleName
        guard centralManager.state == .poweredOn else {
            state = .error("蓝牙未开启")
            return
        }
        state = .scanning
        receivedSamples.removeAll()
        centralManager.scanForPeripherals(
            withServices: [TeslaProtocol.vehicleServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    /// 停止扫描
    func stopScanning() {
        centralManager.stopScan()
    }

    /// 连接指定外设
    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        state = .connecting
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    /// 断开连接
    func disconnect() {
        sessionStage = .idle
        isAuthenticated = false
        sessionKeys = nil
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - 身份配置

    /// 验证并写入 VIN（17 位，排除 I、O、Q）
    /// - Returns: 验证结果
    @discardableResult
    func setVIN(_ vin: String) -> Result<String, String> {
        let trimmed = vin.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 17 else {
            return .failure("VIN 必须是 17 位字符（当前 \(trimmed.count) 位）")
        }
        let invalidChars = CharacterSet(charactersIn: "IOQ")
        let allowedChars = CharacterSet.alphanumerics.subtracting(invalidChars)
        let chars = CharacterSet(charactersIn: trimmed)
        guard chars.isSubset(of: allowedChars) else {
            return .failure("VIN 不能包含字母 I、O、Q")
        }
        self.vin = trimmed
        deviceInfo.vin = trimmed
        saveVIN(trimmed)
        return .success(trimmed)
    }

    /// 导入 P-256 私钥
    /// 支持多种格式：
    /// 1. KEYBEGIN/KEYEND 包裹的 base64 编码私钥（Tesla 导出格式）
    /// 2. PEM 格式（-----BEGIN PRIVATE KEY-----）
    /// 3. 纯 base64 或 hex 编码的 32 字节原始私钥
    /// - Parameter keyContent: 私钥文本内容
    /// - Returns: 导入结果
    @discardableResult
    func importPrivateKey(_ keyContent: String) -> Result<Void, String> {
        let content = keyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return .failure("私钥内容为空")
        }

        // 尝试多种解析方式
        var privateKey: P256.Signing.PrivateKey?

        // 方式 1: KEYBEGIN/KEYEND 包裹格式
        if content.contains("KEYBEGIN") || content.contains("KEY END") {
            let pattern = content.contains("KEYBEGIN") && content.contains("KEYEND")
                ? "KEYBEGIN\\s*(.*?)KEYEND"
                : "KEY\\s*BEGIN\\s*(.*?)KEY\\s*END"
            if let extracted = extractBase64(from: content, pattern: pattern),
               let key = tryParsePrivateKey(base64String: extracted) {
                privateKey = key
            }
        }

        // 方式 2: 标准 PEM 格式
        if privateKey == nil, content.contains("PRIVATE KEY") {
            let pattern = "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\\s*(.*?)\\s*-----END [A-Z0-9 ]*PRIVATE KEY-----"
            if let extracted = extractBase64(from: content, pattern: pattern),
               let key = tryParsePrivateKey(base64String: extracted) {
                privateKey = key
            }
        }

        // 方式 3: 纯 base64 / hex
        if privateKey == nil {
            let cleaned = content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            if let key = tryParsePrivateKey(base64String: cleaned) {
                privateKey = key
            } else if let keyData = hexStringToData(cleaned),
                      let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
                privateKey = key
            }
        }

        guard let key = privateKey else {
            return .failure("私钥格式无效，请确认为有效的 P-256 私钥")
        }

        // 保存私钥到 Keychain
        if TeslaBLEKeyManager.importPrivateKey(key) {
            localPrivateKey = key
            return .success(())
        }
        return .failure("私钥保存失败")
    }

    /// 从文本中提取 base64 内容
    private func extractBase64(from content: String, pattern: String) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            let range = NSRange(location: 0, length: content.utf16.count)
            if let match = regex.firstMatch(in: content, options: [], range: range),
               let swiftRange = Range(match.range(at: 1), in: content) {
                return String(content[swiftRange])
                    .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            }
            // 尝试直接匹配 base64
            let base64Pattern = "[A-Za-z0-9+/=]{20,}"
            let base64Regex = try NSRegularExpression(pattern: base64Pattern)
            let matches = base64Regex.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count))
            if let first = matches.first, let swiftRange = Range(first.range, in: content) {
                return String(content[swiftRange])
            }
        } catch {
            // 回退到整个内容
        }
        return content.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
    }

    /// 从 base64 字符串尝试解析 P-256 私钥
    private func tryParsePrivateKey(base64String: String) -> P256.Signing.PrivateKey? {
        // 方法 1: 直接作为 rawRepresentation（32 字节）
        if let data = Data(base64Encoded: base64String),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }

        // 方法 2: 解析 PEM/DER 格式的 SEC1 或 PKCS8
        if let derData = Data(base64Encoded: base64String),
           let key = parseDERPrivateKey(derData) {
            return key
        }

        // 方法 3: 从 PEM 的 DER 内容中提取 EC 私钥
        if let derData = Data(base64Encoded: base64String),
           let key = parseECPrivateKey(derData) {
            return key
        }

        return nil
    }

    /// 解析 DER 格式私钥（PKCS8 / SEC1）
    private func parseDERPrivateKey(_ der: Data) -> P256.Signing.PrivateKey? {
        // 尝试 PKCS8 格式
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) {
            return key
        }

        // 尝试提取 EC PRIVATE KEY（SEC1）格式中的 32 字节私钥
        // SEC1 ECPrivateKey ASN.1 结构：
        // SEQUENCE {
        //   INTEGER 1,
        //   OCTET STRING (private key 32 bytes),
        //   ...
        // }
        let bytes = [UInt8](der)
        // 寻找 OCTET STRING 类型字节 (0x04)，长度为 0x20 (32)
        if let octetIndex = findASN1OctetString(bytes, length: 32) {
            let keyData = Data(bytes[octetIndex..<octetIndex+32])
            return try? P256.Signing.PrivateKey(rawRepresentation: keyData)
        }
        return nil
    }

    /// 解析 EC PRIVATE KEY 格式
    private func parseECPrivateKey(_ der: Data) -> P256.Signing.PrivateKey? {
        // ECPrivateKey 结构：
        // SEQUENCE {
        //   INTEGER 1,
        //   OCTET STRING 私钥,
        //   [0] { OID secp256r1 },
        //   [1] { BIT STRING 公钥 }
        // }
        let bytes = [UInt8](der)
        if let octetIndex = findASN1OctetString(bytes, length: 32) {
            let keyData = Data(bytes[octetIndex..<octetIndex+32])
            return try? P256.Signing.PrivateKey(rawRepresentation: keyData)
        }
        return nil
    }

    /// 在 ASN.1 DER 编码数据中查找指定长度的 OCTET STRING
    private func findASN1OctetString(_ bytes: [UInt8], length targetLength: Int) -> Int? {
        var index = 0
        while index < bytes.count {
            // 跳过 tag 字节
            let tag = bytes[index]
            index += 1
            if index >= bytes.count { break }

            // 解析长度
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let lengthBytes = length & 0x7F
                if index + lengthBytes > bytes.count { break }
                length = 0
                for _ in 0..<lengthBytes {
                    length = (length << 8) | Int(bytes[index])
                    index += 1
                }
            }

            // 如果是 OCTET STRING (0x04) 且长度匹配
            if tag == 0x04 && length == targetLength {
                return index
            }

            // 跳过内容
            index += length
        }
        return nil
    }

    /// 触发 TRUST 配对（白名单操作）
    func startWhitelist() {
        guard isAuthenticated, let privateKey = localPrivateKey else {
            state = .error("白名单需要先建立加密会话（需已有一个授权密钥）")
            return
        }

        let publicKeyData = privateKey.publicKey.rawRepresentation
        let message = TeslaProtocol.buildWhitelistAddKey(publicKey: publicKeyData)
        sendSignedMessage(message)
        state = .error("请在车辆中控屏确认 TRUST 配对")
    }

    /// 重置密钥
    func resetKeys() {
        TeslaBLEKeyManager.resetKeys()
        loadKeys()
    }

    /// 请求车辆状态（用于更新实时数据）
    func requestVehicleStatus() {
        sendSignedMessage(TeslaProtocol.buildVehicleStatusRequest())
    }

    /// 请求车机信息（固件版本等）
    func requestVehicleInfo() {
        sendSignedMessage(TeslaProtocol.buildVehicleInfoRequest())
    }

    /// 低延迟模式开关
    /// 开启时使用 notify 实时订阅，关闭时减少推送频率
    var isLowLatencyMode: Bool = true {
        didSet {
            updateLowLatencyMode()
        }
    }

    /// 更新低延迟模式
    private func updateLowLatencyMode() {
        guard let peripheral = connectedPeripheral,
              let characteristic = indicateCharacteristic else { return }
        // 开启低延迟：Notify 实时推送
        // 关闭低延迟：暂停 Notify 减少推送，仅手动刷新
        peripheral.setNotifyValue(isLowLatencyMode, for: characteristic)
    }

    /// 发送遥测数据（测试用）
    func sendTelemetry(channel: UInt8, value: Double) {
        guard isAuthenticated else {
            state = .error("未认证，无法发送测试数据")
            return
        }
        let payload = Data(TeslaProtocol.telemetryPayload(value: value, channel: channel))
        sendSignedMessage(payload)
    }

    // MARK: - 私有方法

    private func loadKeys() {
        localPrivateKey = TeslaBLEKeyManager.getOrCreateKeyPair()
    }

    private func loadSavedVIN() {
        if let savedVIN = TeslaBLEKeyManager.getSavedVIN() {
            vin = savedVIN
            deviceInfo.vin = savedVIN
        }
    }

    private func saveVIN(_ vin: String) {
        TeslaBLEKeyManager.saveVIN(vin)
    }

    /// 发送签名命令（符合官方 AES-GCM PERSONALIZED）
    private func sendSignedMessage(_ message: Data, domain: TeslaMetadataSerializer.Domain = .vehicleSecurity) {
        guard isAuthenticated, let keys = sessionKeys, let localPrivateKey = localPrivateKey else {
            state = .error("未认证，无法发送签名命令")
            return
        }
        guard !vin.isEmpty else {
            state = .error("缺少车辆 VIN，无法个性化签名")
            return
        }

        // 客户端公钥 SEC1 编码（04||x||y）
        let clientPublicKey = localPrivateKey.publicKey.rawRepresentation

        guard let signed = TeslaProtocol.buildSignedRoutableMessage(
            payload: message,
            domain: domain,
            vin: vin,
            session: keys,
            clientPublicKey: clientPublicKey
        ) else {
            state = .error("命令签名失败")
            return
        }

        sessionKeys?.counter = signed.counter
        pendingRequestHash = signed.requestHash
        pendingDomain = domain

        writeRoutableMessage(signed.message)
    }

    /// 通过 BLE 写特征发送 RoutableMessage（2 字节大端长度前缀 + 消息体）
    private func writeRoutableMessage(_ message: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else { return }

        var framed = Data()
        framed.append(UInt8((message.count >> 8) & 0xFF))
        framed.append(UInt8(message.count & 0xFF))
        framed.append(message)

        let bytes = [UInt8](framed)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + maxPayloadBytes, bytes.count)
            let chunk = Data(bytes[offset..<end])
            offset = end
            stats.packetsSent += 1
            stats.totalBytesSent += chunk.count
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    /// 处理收到的 BLE 数据
    private func handleReceivedFrame(_ data: Data) {
        frameSubject.send(data)
        stats.packetsReceived += 1
        stats.totalBytesReceived += data.count

        receiveBuffer.append(data)

        while receiveBuffer.count >= 2 {
            let bytes = [UInt8](receiveBuffer)
            let msgLength = (Int(bytes[0]) << 8) | Int(bytes[1])
            guard receiveBuffer.count >= 2 + msgLength else { break }

            let body = receiveBuffer.subdata(
                in: receiveBuffer.startIndex..<receiveBuffer.startIndex + 2 + msgLength
            ).dropFirst(2)
            receiveBuffer.removeFirst(2 + msgLength)

            handleRoutableMessage(Data(body))
        }
    }

    /// 处理一条 RoutableMessage（握手响应 / 命令响应）
    private func handleRoutableMessage(_ data: Data) {
        let fields = TeslaProtobuf.decodeFields(data)

        // 握手响应：包含 session_info (field15)
        if TeslaProtobuf.getBytes(fields, field: 15) != nil {
            handleSessionInfoResponse(data)
            return
        }

        // 命令响应：加密负载
        guard let keys = sessionKeys else {
            parseVehicleResponse(data)
            return
        }
        parseEncryptedResponse(data, keys: keys)
    }

    /// 处理握手（session info）响应
    private func handleSessionInfoResponse(_ data: Data) {
        guard let parsed = TeslaProtocol.parseSessionInfoResponse(data) else {
            state = .error("解析会话信息失败")
            return
        }

        guard let localPrivateKey = localPrivateKey else { return }
        guard let key = TeslaBLESessionCrypto.deriveSessionKey(
            localPrivateKey: localPrivateKey,
            vehiclePublicKeyRaw: parsed.vehiclePublicKey
        ) else {
            state = .error("密钥派生失败")
            return
        }

        // 验证 session info tag（防 MITM）
        guard let handshakeUUID = handshakeUUID else { return }
        let sessionInfoKey = TeslaBLESessionCrypto.sessionInfoKey(from: key)
        let metadata = TeslaMetadataSerializer.sessionInfoMetadata(vin: vin, challenge: handshakeUUID)
        let expectedTag = TeslaBLESessionCrypto.hmac(
            metadata + parsedSessionInfoBytes(from: data),
            key: sessionInfoKey
        )

        guard TeslaBLESessionCrypto.constantTimeEquals(expectedTag, parsed.sessionInfoTag) else {
            state = .error("会话信息认证失败（MITM 风险）")
            return
        }

        // 建立会话
        sessionKeys = TeslaBLESessionCrypto.SessionKeys(
            sessionKey: key,
            epoch: parsed.epoch,
            counter: parsed.counter,
            clockTime: parsed.clockTime,
            clockOffset: Double(Date().timeIntervalSince1970) - Double(parsed.clockTime)
        )

        isAuthenticated = true
        sessionStage = .authenticated
        state = .connected

        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.isPaired = true
            self?.deviceInfo.linkState = "已认证"
        }

        // 认证成功后请求车辆状态和车机信息
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestVehicleStatus()
            self?.requestVehicleInfo()
        }
    }

    /// 提取 session_info 原始字节用于 HMAC 认证
    private func parsedSessionInfoBytes(from data: Data) -> Data {
        let fields = TeslaProtobuf.decodeFields(data)
        return TeslaProtobuf.getBytes(fields, field: 15) ?? Data()
    }

    /// 解析加密的命令响应
    private func parseEncryptedResponse(_ data: Data, keys: TeslaBLESessionCrypto.SessionKeys) {
        let fields = TeslaProtobuf.decodeFields(data)

        guard let payload = TeslaProtobuf.getBytes(fields, field: 10) else {
            return
        }

        guard let sigData = TeslaProtobuf.getBytes(fields, field: 13),
              let aesResp = TeslaProtobuf.getBytes(TeslaProtobuf.decodeFields(sigData), field: 9) else {
            parseVehicleResponse(payload)
            return
        }

        let aesFields = TeslaProtobuf.decodeFields(aesResp)
        guard let nonce = TeslaProtobuf.getBytes(aesFields, field: 1),
              let tag = TeslaProtobuf.getBytes(aesFields, field: 3) else {
            return
        }
        let counter = UInt32(TeslaProtobuf.getVarint(aesFields, field: 2) ?? 0)
        let flags = UInt32(TeslaProtobuf.getVarint(fields, field: 52) ?? 0)

        guard let pendingRequestHash = pendingRequestHash else { return }
        let responseMetadata = TeslaMetadataSerializer.responseMetadata(
            domain: pendingDomain ?? .vehicleSecurity,
            vin: vin,
            counter: counter,
            flags: flags,
            requestHash: pendingRequestHash
        )
        let aad = Data(SHA256.hash(data: responseMetadata))

        let combined = payload + tag
        if let plaintext = TeslaBLESessionCrypto.open(
            combined,
            key: keys.sessionKey,
            nonce: nonce,
            aad: aad
        ) {
            parseVehicleResponse(plaintext)
        }
    }

    /// 解析车辆响应消息
    private func parseVehicleResponse(_ data: Data) {
        let fields = TeslaProtobuf.decodeFields(data)

        // VCSEC FromVCSECMessage: vehicleStatus (field1)
        if let vehicleStatusData = TeslaProtobuf.getBytes(fields, field: 1) {
            parseVehicleStatus(vehicleStatusData)
        }

        // 车机信息（field2: 固件版本等）
        if let infoData = TeslaProtobuf.getBytes(fields, field: 2) {
            parseVehicleInfo(infoData)
        }

        // 记录原始响应
        DispatchQueue.main.async { [weak self] in
            let sample = TelemetrySample(
                channel: "raw",
                rawPayload: data.map { String(format: "%02X", $0) }.joined(),
                value: Double(fields.count),
                unit: ""
            )
            self?.receivedSamples.append(sample)
            if let count = self?.receivedSamples.count, count > 200 {
                self?.receivedSamples.removeFirst(count - 200)
            }
        }
    }

    /// 解析车辆状态（锁状态、车速等）
    private func parseVehicleStatus(_ data: Data) {
        let vsFields = TeslaProtobuf.decodeFields(data)

        // VehicleStatus.vehicleLockState (field2)
        let lockState = UInt32(TeslaProtobuf.getVarint(vsFields, field: 2) ?? 0)
        let locked = (lockState == 1 || lockState == 2)

        // 速度等遥测数据 - 尝试解析各字段
        // field3: speed, field4: battery, field5: odometer
        let speed = parseDoubleFromField(vsFields, field: 3)
        let battery = UInt32(TeslaProtobuf.getVarint(vsFields, field: 4) ?? 0)
        let odometer = parseDoubleFromField(vsFields, field: 5)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var state = self.vehicleState
            state.locked = locked
            if speed > 0 { state.speedKmh = speed }
            if battery > 0 { state.batteryLevel = Int(battery) }
            if odometer > 0 { state.odometerKm = odometer }
            self.vehicleState = state

            let sample = TelemetrySample(
                channel: "vehicleStatus",
                rawPayload: data.map { String(format: "%02X", $0) }.joined(),
                value: Double(lockState),
                unit: ""
            )
            self.receivedSamples.append(sample)
            if self.receivedSamples.count > 200 {
                self.receivedSamples.removeFirst(self.receivedSamples.count - 200)
            }
        }
    }

    /// 解析车机信息（固件版本等）
    private func parseVehicleInfo(_ data: Data) {
        let infoFields = TeslaProtobuf.decodeFields(data)

        // 尝试提取固件版本字符串
        if let fwData = TeslaProtobuf.getBytes(infoFields, field: 1),
           let fwVersion = String(data: fwData, encoding: .utf8) {
            DispatchQueue.main.async { [weak self] in
                self?.deviceInfo.firmwareVersion = fwVersion
            }
        }
    }

    /// 从 protobuf 字段中解析 double 值
    private func parseDoubleFromField(_ fields: [(Int, Int, Data)], field: Int) -> Double {
        guard let data = TeslaProtobuf.getBytes(fields, field: field),
              data.count == 8 else { return 0 }
        let bytes = [UInt8](data)
        var raw: UInt64 = 0
        for i in 0..<8 {
            raw |= UInt64(bytes[i]) << (UInt64(i) * 8)
        }
        return Double(bitPattern: raw)
    }

    /// hex 字符串转 Data
    private func hexStringToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    func updateThroughput(elapsed: TimeInterval) {
        guard elapsed > 0 else { return }
        stats.throughputBytesPerSec = Double(stats.totalBytesReceived) / elapsed
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if state == .scanning || state == .idle {
                startScanning(vehicleName: targetVehicleName)
            }
        case .poweredOff:
            state = .error("蓝牙未开启，请在设置中打开蓝牙")
        case .unauthorized:
            state = .error("未获得蓝牙权限")
        case .unsupported:
            state = .error("该设备不支持 BLE")
        default:
            state = .disconnected("蓝牙状态变化")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 更新信号强度
        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.rssi = RSSI.intValue
        }

        // 记录车辆信息
        if let name = peripheral.name {
            DispatchQueue.main.async { [weak self] in
                self?.deviceInfo.vehicleName = name
                if let vehicleID = TeslaProtocol.vehicleID(fromLocalName: name) {
                    self?.deviceInfo.vehicleID = vehicleID
                }
            }
        }

        // 过滤 Tesla 设备
        if let name = peripheral.name {
            if name.contains("Tesla") || name.contains("S") {
                connect(to: peripheral)
            }
        } else {
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        sessionStage = .idle
        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.linkState = "发现服务中"
        }
        peripheral.discoverServices([TeslaProtocol.vehicleServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error(error?.localizedDescription ?? "连接失败")
        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.linkState = "连接失败"
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected(error?.localizedDescription ?? "设备断开")
        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.linkState = "已断开"
            self?.deviceInfo.isPaired = false
        }
        connectedPeripheral = nil
        writeCharacteristic = nil
        indicateCharacteristic = nil
        batteryCharacteristic = nil
        deviceNameCharacteristic = nil
        isAuthenticated = false
        sessionKeys = nil
        handshakeUUID = nil
        pendingRequestHash = nil
        pendingDomain = nil
        receiveBuffer.removeAll()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            state = .error(error!.localizedDescription)
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(
                [TeslaProtocol.writeCharacteristicUUID,
                 TeslaProtocol.indicateCharacteristicUUID,
                 TeslaProtocol.batteryUUID,
                 TeslaProtocol.deviceNameUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case TeslaProtocol.writeCharacteristicUUID:
                writeCharacteristic = characteristic
            case TeslaProtocol.indicateCharacteristicUUID:
                indicateCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case TeslaProtocol.batteryUUID:
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            case TeslaProtocol.deviceNameUUID:
                deviceNameCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }

        if writeCharacteristic != nil && indicateCharacteristic != nil {
            state = .connected
            DispatchQueue.main.async { [weak self] in
                self?.deviceInfo.linkState = "已连接，等待密钥协商"
            }
            sessionStage = .awaitingVehiclePublicKey
            requestSessionNegotiation()
        }
    }

    /// 发起密钥协商（session_info_request）
    private func requestSessionNegotiation() {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic,
              let localPrivateKey = localPrivateKey else { return }

        let publicKeyData = localPrivateKey.publicKey.rawRepresentation

        let (request, uuid) = TeslaProtocol.buildSessionInfoRequest(clientPublicKey: publicKeyData)
        handshakeUUID = uuid

        var framed = Data()
        framed.append(UInt8((request.count >> 8) & 0xFF))
        framed.append(UInt8(request.count & 0xFF))
        framed.append(request)

        let bytes = [UInt8](framed)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + maxPayloadBytes, bytes.count)
            let chunk = Data(bytes[offset..<end])
            offset = end
            peripheral.writeValue(chunk, for: writeChar, type: .withResponse)
        }
        sessionStage = .awaitingSessionInfo
        DispatchQueue.main.async { [weak self] in
            self?.deviceInfo.linkState = "密钥协商中…"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying {
            state = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }

        switch characteristic.uuid {
        case TeslaProtocol.indicateCharacteristicUUID:
            handleReceivedFrame(value)
        case TeslaProtocol.batteryUUID:
            if let battery = value.first {
                DispatchQueue.main.async { [weak self] in
                    self?.vehicleState.batteryLevel = Int(battery)
                    self?.deviceInfo.batteryLevel = Int(battery)
                }
            }
        case TeslaProtocol.deviceNameUUID:
            if let name = String(data: value, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in
                    self?.deviceInfo.vehicleName = name
                }
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil {
            print("Write error: \(error!.localizedDescription)")
        }
    }
}
