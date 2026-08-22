import Foundation
import CoreBluetooth
import Combine
import CryptoKit

/// Tesla BLE 蓝牙服务
///
/// 作为 CBCentralManager 管理端，负责扫描、连接 Tesla 车辆，
/// 建立加密通信通道（P-256 ECDH + AES-GCM），
/// 支持 VCSEC 安全命令与 Infotainment 数据查询。
///
/// 连接流程：
/// 1. 扫描并连接 Tesla 车辆
/// 2. 发现 BLE 服务与特征
/// 3. 密钥协商（ECDH + 会话密钥派生）
/// 4. 白名单认证（首次需车内确认）
/// 5. 加密发送命令 / 解密接收响应
final class BLEService: NSObject, ObservableObject {

    // MARK: - 对外状态发布
    @Published var state: BLEConnectionState = .idle
    @Published var receivedSamples: [TelemetrySample] = []
    @Published var stats = TransferStats()
    @Published var vehicleState = TeslaProtocol.TeslaVehicleState()
    @Published var sessionStage: TeslaProtocol.SessionStage = .idle
    @Published var isAuthenticated = false

    /// 接收到的原始数据帧流（供 ViewModel 订阅）
    let frameSubject = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var indicateCharacteristic: CBCharacteristic?

    // 会话密钥
    private var localPrivateKey: P256.Signing.PrivateKey?
    private var sessionKeys: TeslaBLESessionCrypto.SessionKeys?
    private var vehiclePublicKey: Data?

    /// 车辆 VIN（用于命令个性化签名）
    /// 通过扫描到的蓝牙名称 `S+ID+C` 提取，或由用户手动设置
    var vin: String = ""

    /// 握手请求的 uuid（用于 session info 认证 challenge）
    private var handshakeUUID: Data?
    /// 最近一次发送命令的 requestHash（用于响应解密）
    private var pendingRequestHash: Data?
    /// 最近一次发送命令的 domain
    private var pendingDomain: TeslaMetadataSerializer.Domain?

    /// BLE 传输层：接收缓冲区（累积 2 字节长度前缀 + 消息体）
    private var receiveBuffer = Data()

    // 消息序号
    private var messageCounter: UInt32 = 0

    /// 已发送但尚未 ACK 的序列号集合
    private var pendingAcks: Set<UInt16> = []
    /// 用于延迟测量的时间戳表
    private var sendTimestamps: [UInt16: Date] = [:]

    /// 车辆名称（扫描过滤用）
    private var targetVehicleName: String?

    private let maxPayloadBytes = 120

    // MARK: - 初始化
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadKeys()
    }

    // MARK: - 对外接口

    /// 开始扫描 Tesla 车辆
    /// - Parameter vehicleName: 可选，指定车辆名称过滤（如 "Tesla-XXXXXX"）
    func startScanning(vehicleName: String? = nil) {
        targetVehicleName = vehicleName
        guard centralManager.state == .poweredOn else {
            state = .error("蓝牙未开启")
            return
        }
        state = .scanning
        receivedSamples.removeAll()
        // 按 Tesla 服务 UUID 扫描
        centralManager.scanForPeripherals(withServices: [TeslaProtocol.vehicleServiceUUID],
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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

    // MARK: - 发送命令

    /// 发送锁车命令
    func sendLockCommand() {
        sendSignedMessage(TeslaProtocol.buildLockCommand())
    }

    /// 发送解锁命令
    func sendUnlockCommand() {
        sendSignedMessage(TeslaProtocol.buildUnlockCommand())
    }

    /// 发送鸣笛命令
    func sendHonkCommand() {
        sendSignedMessage(TeslaProtocol.buildHonkCommand())
    }

    /// 发送闪灯命令
    func sendFlashCommand() {
        sendSignedMessage(TeslaProtocol.buildFlashCommand())
    }

    /// 发送车辆状态请求
    func requestVehicleStatus() {
        sendSignedMessage(TeslaProtocol.buildVehicleStatusRequest())
    }

    /// 发送自定义数据（通过签名 RoutableMessage 发送）
    func sendCustomData(_ payload: [UInt8]) {
        guard isAuthenticated else {
            state = .error("未认证，请先完成白名单")
            return
        }
        sendSignedMessage(Data(payload))
    }

    /// 发送遥测数据（测试用，通过签名消息封装）
    func sendTelemetry(channel: UInt8, value: Double) {
        guard isAuthenticated else { return }
        let payload = Data(TeslaProtocol.telemetryPayload(value: value, channel: channel))
        sendSignedMessage(payload)
    }

    /// 触发白名单操作（需在车内中控屏/NFC 确认）
    /// 官方流程：需由已在车辆上的授权密钥（Service 或 Owner）签名该操作，首次配对需配合 NFC 卡。
    func startWhitelist() {
        guard isAuthenticated, let privateKey = localPrivateKey else {
            state = .error("白名单需要先建立加密会话（需已有一个授权密钥）")
            return
        }

        let publicKeyData = privateKey.publicKey.rawRepresentation
        // VCSEC WhitelistOperation: addPublicKeyToWhitelist
        let message = TeslaProtocol.buildWhitelistAddKey(publicKey: publicKeyData)
        sendSignedMessage(message)
        state = .error("请在车辆中控屏确认配对（需 NFC 卡或已授权密钥）")
    }

    /// 重置密钥
    func resetKeys() {
        TeslaBLEKeyManager.resetKeys()
        loadKeys()
    }

    // MARK: - 私有方法

    private func loadKeys() {
        localPrivateKey = TeslaBLEKeyManager.getOrCreateKeyPair()
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

        // 更新会话 counter（每次命令递增）
        sessionKeys?.counter = signed.counter
        // 记录用于响应解密
        pendingRequestHash = signed.requestHash
        pendingDomain = domain

        // 通过 BLE 传输：2 字节大端长度前缀 + RoutableMessage
        writeRoutableMessage(signed.message)
    }

    /// 通过 BLE 写特征发送 RoutableMessage（官方格式：2 字节大端长度前缀 + 消息体）
    private func writeRoutableMessage(_ message: Data) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic else { return }

        var framed = Data()
        // 2 字节大端长度前缀
        framed.append(UInt8((message.count >> 8) & 0xFF))
        framed.append(UInt8(message.count & 0xFF))
        framed.append(message)

        // 分块发送（每次 write with response）
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
        // 记录发送时间用于延迟统计
        stats.lastLatencyMs = 0
    }

    /// 处理收到的 BLE 数据（累积 2 字节长度前缀的完整消息后解析）
    private func handleReceivedFrame(_ data: Data) {
        frameSubject.send(data)
        stats.packetsReceived += 1
        stats.totalBytesReceived += data.count

        // 累积到接收缓冲区
        receiveBuffer.append(data)

        // 循环解析可能的多条完整消息
        while receiveBuffer.count >= 2 {
            let bytes = [UInt8](receiveBuffer)
            let msgLength = (Int(bytes[0]) << 8) | Int(bytes[1])
            guard receiveBuffer.count >= 2 + msgLength else { break }

            // 提取一条完整 RoutableMessage
            let msg = receiveBuffer.subdata(in: receiveBuffer.startIndex..<receiveBuffer.startIndex + 2 + msgLength)
            let body = msg.dropFirst(2)
            receiveBuffer.removeFirst(2 + msgLength)

            handleRoutableMessage(Data(body))
        }
    }

    /// 处理一条 RoutableMessage（握手响应 / 命令响应）
    private func handleRoutableMessage(_ data: Data) {
        let fields = TeslaProtobuf.decodeFields(data)

        // 1) 握手响应：包含 session_info (field15)
        if TeslaProtobuf.getBytes(fields, field: 15) != nil {
            handleSessionInfoResponse(data)
            return
        }

        // 2) 命令响应：加密负载 (field10) + AES_GCM_Response_data
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

        // 派生共享密钥 K = SHA1(Sx)[:16]
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
        let expectedTag = TeslaBLESessionCrypto.hmac(metadata + parsedSessionInfoBytes(from: data), key: sessionInfoKey)

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

        // 认证成功后请求车辆状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestVehicleStatus()
        }
    }

    /// 从 session info 响应中提取原始 session_info 字节（field15），用于 HMAC 认证
    private func parsedSessionInfoBytes(from data: Data) -> Data {
        let fields = TeslaProtobuf.decodeFields(data)
        return TeslaProtobuf.getBytes(fields, field: 15) ?? Data()
    }

    /// 解析加密的命令响应（AES-GCM Response 解密）
    private func parseEncryptedResponse(_ data: Data, keys: TeslaBLESessionCrypto.SessionKeys) {
        let fields = TeslaProtobuf.decodeFields(data)

        // 提取 payload (field10)
        guard let payload = TeslaProtobuf.getBytes(fields, field: 10) else {
            // 无负载，仅状态
            handleAck(sequence: 0, timestamp: Date())
            return
        }

        // 提取 signature_data (field13) → AES_GCM_Response_data (field9)
        guard let sigData = TeslaProtobuf.getBytes(fields, field: 13),
              let aesResp = TeslaProtobuf.getBytes(TeslaProtobuf.decodeFields(sigData), field: 9) else {
            // 旧固件可能返回明文
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

        // 构建响应解密 Metadata
        guard let pendingRequestHash = pendingRequestHash else { return }
        let responseMetadata = TeslaMetadataSerializer.responseMetadata(
            domain: pendingDomain ?? .vehicleSecurity,
            vin: vin,
            counter: counter,
            flags: flags,
            requestHash: pendingRequestHash
        )
        let aad = Data(SHA256.hash(data: responseMetadata))

        // 分离密文与 tag
        let combined = payload + tag
        if let plaintext = TeslaBLESessionCrypto.open(
            combined,
            key: keys.sessionKey,
            nonce: nonce,
            aad: aad
        ) {
            handleAck(sequence: 0, timestamp: Date())
            parseVehicleResponse(plaintext)
        }
    }

    /// 解析车辆响应消息
    private func parseVehicleResponse(_ data: Data) {
        let fields = TeslaProtobuf.decodeFields(data)

        // VCSEC FromVCSECMessage: vehicleStatus (field1) 内含锁状态
        if let vehicleStatusData = TeslaProtobuf.getBytes(fields, field: 1) {
            let vsFields = TeslaProtobuf.decodeFields(vehicleStatusData)
            // VehicleStatus.vehicleLockState (field2): UNLOCKED=0, LOCKED=1
            let lockState = UInt32(TeslaProtobuf.getVarint(vsFields, field: 2) ?? 0)
            let locked = (lockState == 1 || lockState == 2) // LOCKED / INTERNAL_LOCKED

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var state = self.vehicleState
                state.locked = locked
                self.vehicleState = state
                // 记录原始响应样本
                let sample = TelemetrySample(
                    channel: "vehicleStatus",
                    rawPayload: vehicleStatusData.map { String(format: "%02X", $0) }.joined(),
                    value: Double(lockState),
                    unit: ""
                )
                self.receivedSamples.append(sample)
                if self.receivedSamples.count > 200 {
                    self.receivedSamples.removeFirst(self.receivedSamples.count - 200)
                }
            }
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

    /// 收到确认，更新延迟统计
    private func handleAck(sequence: UInt16, timestamp: Date) {
        guard let sentAt = sendTimestamps.removeValue(forKey: sequence) else { return }
        pendingAcks.remove(sequence)
        let latency = timestamp.timeIntervalSince(sentAt) * 1000 // ms
        stats.lastLatencyMs = latency
        if stats.averageLatencyMs == 0 {
            stats.averageLatencyMs = latency
        } else {
            stats.averageLatencyMs = stats.averageLatencyMs * 0.9 + latency * 0.1
        }
    }

    private func unit(for channel: UInt8) -> String {
        switch channel {
        case 1: return "km/h"
        case 2: return "%"
        case 3: return "km"
        case 4: return "°C"
        default: return ""
        }
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
        // 过滤 Tesla 设备：名称包含 "Tesla" 或广播中包含 Tesla 服务
        if let name = peripheral.name {
            if name.contains("Tesla") || name.contains("S") {
                // 记录车辆广播 ID（S+ID+C 中的 ID，为 VIN 的 SHA1 前 8 字节 hex）
                if let vehicleID = TeslaProtocol.vehicleID(fromLocalName: name) {
                    print("Tesla vehicle ID: \(vehicleID)")
                }
                connect(to: peripheral)
            }
        } else {
            // 名称未知但仍包含 Tesla 服务，尝试连接
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        sessionStage = .idle
        peripheral.discoverServices([TeslaProtocol.vehicleServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error(error?.localizedDescription ?? "连接失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected(error?.localizedDescription ?? "设备断开")
        connectedPeripheral = nil
        writeCharacteristic = nil
        indicateCharacteristic = nil
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
                // 订阅 indicate 通知
                peripheral.setNotifyValue(true, for: characteristic)
            case TeslaProtocol.batteryUUID, TeslaProtocol.deviceNameUUID:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }

        // 检查是否所有必要特征都已找到
        if writeCharacteristic != nil && indicateCharacteristic != nil {
            state = .connected
            sessionStage = .awaitingVehiclePublicKey
            // 发起密钥协商请求
            requestSessionNegotiation()
        }
    }

    /// 发起密钥协商（发送 session_info_request 握手消息）
    private func requestSessionNegotiation() {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic,
              let localPrivateKey = localPrivateKey else { return }

        // 客户端公钥 SEC1 编码（04||x||y）
        let publicKeyData = localPrivateKey.publicKey.rawRepresentation

        // 构建 session_info_request RoutableMessage
        let (request, uuid) = TeslaProtocol.buildSessionInfoRequest(clientPublicKey: publicKeyData)
        handshakeUUID = uuid

        // 官方 BLE 格式：2 字节大端长度前缀 + 消息体
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
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying {
            state = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }

        // 根据特征分派
        switch characteristic.uuid {
        case TeslaProtocol.indicateCharacteristicUUID:
            handleReceivedFrame(value)
        case TeslaProtocol.batteryUUID:
            // 电池电量
            if let battery = value.first {
                DispatchQueue.main.async { [weak self] in
                    self?.vehicleState.batteryLevel = Int(battery)
                }
            }
        case TeslaProtocol.deviceNameUUID:
            // 设备名称
            if let name = String(data: value, encoding: .utf8) {
                print("Tesla device name: \(name)")
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
