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

    // 消息序号
    private var messageCounter: UInt32 = 0
    private var sequenceCounter: UInt16 = 0

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

    /// 发送自定义数据（用于低延迟收发测试）
    func sendCustomData(_ payload: [UInt8]) {
        guard isAuthenticated else {
            state = .error("未认证，请先完成白名单")
            return
        }
        send(command: .control, payload: payload)
    }

    /// 发送遥测数据（测试用）
    func sendTelemetry(channel: UInt8, value: Double) {
        send(command: .telemetry, payload: TeslaProtocol.telemetryPayload(value: value, channel: channel))
    }

    /// 触发白名单操作（需在车内中控屏确认）
    func startWhitelist() {
        guard let privateKey = localPrivateKey, let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic else {
            state = .error("无法开始白名单")
            return
        }

        // 发送公钥给车辆进行白名单
        let publicKeyData = privateKey.publicKey.rawRepresentation

        // VCSEC WhitelistOperation message
        // 简化实现：将公钥直接发送给车辆
        let message = Data(publicKeyData)
        peripheral.writeValue(message, for: writeChar, type: .withResponse)
        state = .error("请在车辆中控屏确认配对")
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

    private func nextSequence() -> UInt16 {
        sequenceCounter = sequenceCounter &+ 1
        return sequenceCounter
    }

    /// 发送签名命令（加密）
    private func sendSignedMessage(_ message: Data) {
        guard isAuthenticated, let keys = sessionKeys else {
            state = .error("未认证，无法发送签名命令")
            return
        }

        // 加密消息
        guard let encrypted = TeslaBLESessionCrypto.encrypt(message, with: keys.sessionKey) else {
            state = .error("加密失败")
            return
        }

        // 添加 HMAC 认证
        let mac = TeslaBLESessionCrypto.hmac(encrypted, key: keys.macKey)

        // 构建完整消息：encrypted + mac
        var fullMessage = Data()
        fullMessage.append(encrypted)
        fullMessage.append(mac)

        // 通过帧封装发送
        let payload = [UInt8](fullMessage)
        send(command: .control, payload: payload)
    }

    /// 发送一帧数据
    func send(command: TeslaProtocol.CommandType, payload: [UInt8]) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              state.isConnected else {
            return
        }

        let sequence = nextSequence()
        let data = TeslaProtocol.encodeFrame(type: command, sequence: sequence, payload: payload)

        if data.count <= maxPayloadBytes {
            sendFrame(data, sequence: sequence, to: peripheral, characteristic: characteristic)
        } else {
            splitAndSend(data, sequence: sequence, to: peripheral, characteristic: characteristic)
        }
    }

    private func sendFrame(_ data: Data, sequence: UInt16, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        pendingAcks.insert(sequence)
        sendTimestamps[sequence] = Date()
        stats.packetsSent += 1
        stats.totalBytesSent += data.count
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func splitAndSend(_ data: Data, sequence: UInt16, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let end = min(offset + maxPayloadBytes, bytes.count)
            let chunk = Data(bytes[offset..<end])
            offset = end
            stats.packetsSent += 1
            stats.totalBytesSent += chunk.count
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
        pendingAcks.insert(sequence)
        sendTimestamps[sequence] = Date()
    }

    private func handleReceivedFrame(_ data: Data) {
        frameSubject.send(data)
        stats.packetsReceived += 1
        stats.totalBytesReceived += data.count

        // 尝试解析传输层帧
        guard let frame = TeslaProtocol.decodeFrame(data) else {
            // 可能是原始 BLE 消息（非帧封装），直接处理
            handleRawMessage(data)
            return
        }

        switch frame.type {
        case .ack, .pong, .statusResponse, .telemetryResponse, .controlResponse:
            handleAck(sequence: frame.sequence, timestamp: Date())
            handleRawMessage(Data(frame.payload))
        case .telemetry:
            // 解析遥测数据
            if frame.payload.count >= 1 {
                let channel = frame.payload[0]
                let value = TeslaProtocol.parseDouble(from: frame.payload)
                let sample = TelemetrySample(channel: "ch\(channel)",
                                             rawPayload: frame.payload.map { String(format: "%02X", $0) }.joined(),
                                             value: value,
                                             unit: unit(for: channel))
                DispatchQueue.main.async { [weak self] in
                    self?.receivedSamples.append(sample)
                    if let count = self?.receivedSamples.count, count > 200 {
                        self?.receivedSamples.removeFirst(count - 200)
                    }
                }
            }
        default:
            break
        }
    }

    /// 处理未封装帧的原始消息（密钥协商、白名单等）
    private func handleRawMessage(_ data: Data) {
        // 检查是否为车辆公钥响应
        let bytes = [UInt8](data)
        if bytes.count == 65 && (bytes[0] == 0x04 || bytes[0] == 0x02 || bytes[0] == 0x03) {
            // SEC1 编码的公钥
            vehiclePublicKey = data
            handleVehiclePublicKeyReceived()
            return
        }

        // 如果是加密数据，尝试解密
        if isAuthenticated, let keys = sessionKeys, data.count > 28 {
            // 分离 MAC (后 32 字节) 和加密数据
            let macData = data.suffix(32)
            let encryptedData = data.prefix(data.count - 32)

            // 验证 HMAC
            let expectedMAC = TeslaBLESessionCrypto.hmac(encryptedData, key: keys.macKey)
            if macData == expectedMAC {
                if let decrypted = TeslaBLESessionCrypto.decrypt(encryptedData, with: keys.sessionKey) {
                    parseVehicleResponse(decrypted)
                }
            }
        }
    }

    /// 处理车辆公钥接收
    private func handleVehiclePublicKeyReceived() {
        guard let localPrivateKey = localPrivateKey,
              let vehiclePublicKey = vehiclePublicKey else { return }

        // 派生会话密钥
        sessionKeys = TeslaBLESessionCrypto.deriveSessionKeys(
            localPrivateKey: localPrivateKey,
            vehiclePublicKeyRaw: vehiclePublicKey
        )

        if sessionKeys != nil {
            isAuthenticated = true
            sessionStage = .authenticated
            state = .connected
            // 请求车辆状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.requestVehicleStatus()
            }
        } else {
            state = .error("密钥协商失败")
        }
    }

    /// 解析车辆响应消息
    private func parseVehicleResponse(_ data: Data) {
        let fields = TeslaProtobuf.decodeFields(data)

        // 尝试解析车辆状态
        if TeslaProtobuf.getVarint(fields, field: 1) != nil {
            // 更新状态
            DispatchQueue.main.async { [weak self] in
                self?.vehicleState = TeslaProtocol.TeslaVehicleState(
                    batteryLevel: Int(TeslaProtobuf.getVarint(fields, field: 2) ?? 0),
                    locked: (TeslaProtobuf.getVarint(fields, field: 3) ?? 0) == 1,
                    chargePortOpen: (TeslaProtobuf.getVarint(fields, field: 4) ?? 0) == 1,
                    charging: (TeslaProtobuf.getVarint(fields, field: 5) ?? 0) == 1,
                    climateOn: (TeslaProtobuf.getVarint(fields, field: 6) ?? 0) == 1,
                    sentryMode: (TeslaProtobuf.getVarint(fields, field: 7) ?? 0) == 1
                )
            }
        }

        // 创建样本记录
        let sample = TelemetrySample(
            channel: "vehicle",
            rawPayload: data.map { String(format: "%02X", $0) }.joined(),
            value: Double(fields.count),
            unit: ""
        )
        DispatchQueue.main.async { [weak self] in
            self?.receivedSamples.append(sample)
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

    /// 发起密钥协商
    private func requestSessionNegotiation() {
        guard let peripheral = connectedPeripheral,
              let writeChar = writeCharacteristic,
              let localPrivateKey = localPrivateKey else { return }

        // 发送本地公钥进行 ECDH 协商
        let publicKeyData = localPrivateKey.publicKey.rawRepresentation
        peripheral.writeValue(publicKeyData, for: writeChar, type: .withResponse)
        sessionStage = .awaitingVehiclePublicKey
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
