import Foundation
import CoreBluetooth
import Combine

/// Tesla BLE 蓝牙服务
///
/// 作为 CBCentralManager 管理端，负责扫描、连接 Tesla 车辆，
/// 建立低延迟数据通道（Notify + Write），并对外发布收发事件流。
/// 低延迟优化点：
///   - 使用 notify 接收实时数据，避免轮询
///   - 通过序列号 + CRC 实现丢包检测与低延迟确认
///   - 数据帧切分（最大 BLE MTU 128 字节）保证单帧低延迟
final class BLEService: NSObject, ObservableObject {

    // MARK: - 对外状态发布
    @Published var state: BLEConnectionState = .idle
    @Published var receivedSamples: [TelemetrySample] = []
    @Published var stats = TransferStats()

    /// 接收到的原始数据帧流（供 ViewModel 订阅）
    let frameSubject = PassthroughSubject<Data, Never>()

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?

    /// 已发送但尚未 ACK 的序列号集合，用于丢包检测
    private var pendingAcks: Set<UInt16> = []
    private var sequenceCounter: UInt16 = 0
    /// 用于延迟测量的时间戳表
    private var sendTimestamps: [UInt16: Date] = [:]

    private let maxPayloadBytes = 120 // 小于默认 MTU(128)，保证低延迟单帧发送

    // MARK: - 初始化
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 对外接口

    /// 开始扫描 Tesla 车辆
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            state = .error("蓝牙未开启")
            return
        }
        state = .scanning
        receivedSamples.removeAll()
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
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// 发送一帧数据（写请求），并开始延迟测量
    func send(command: TeslaProtocol.CommandType, payload: [UInt8]) {
        guard let peripheral = connectedPeripheral,
              let characteristic = dataCharacteristic,
              state.isConnected else {
            return
        }

        let sequence = nextSequence()
        let data = TeslaProtocol.encodeFrame(type: command, sequence: sequence, payload: payload)

        // 低延迟发送：若超过 MTU 则切分，否则单帧直发
        if data.count <= maxPayloadBytes {
            sendFrame(data, sequence: sequence, to: peripheral, characteristic: characteristic)
        } else {
            splitAndSend(data, sequence: sequence, to: peripheral, characteristic: characteristic)
        }
    }

    /// 发送遥测数据（测试用，模拟车辆下行数据时使用）
    func sendTelemetry(channel: UInt8, value: Double) {
        send(command: .telemetry, payload: TeslaProtocol.telemetryPayload(value: value, channel: channel))
    }

    // MARK: - 私有方法

    private func nextSequence() -> UInt16 {
        sequenceCounter = sequenceCounter &+ 1
        return sequenceCounter
    }

    private func sendFrame(_ data: Data, sequence: UInt16, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        pendingAcks.insert(sequence)
        sendTimestamps[sequence] = Date()
        stats.packetsSent += 1
        stats.totalBytesSent += data.count
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    /// 将大数据切分为多个分片依次发送
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
        // 转发原始帧
        frameSubject.send(data)
        stats.packetsReceived += 1
        stats.totalBytesReceived += data.count

        guard let frame = TeslaProtocol.decodeFrame(data) else { return }

        switch frame.type {
        case .ack, .pong, .statusResponse, .telemetryResponse, .controlResponse:
            handleAck(sequence: frame.sequence, timestamp: Date())
        case .telemetry:
            // 解析车辆下发的遥测数据用于显示
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

    /// 收到确认，更新延迟统计
    private func handleAck(sequence: UInt16, timestamp: Date) {
        guard let sentAt = sendTimestamps.removeValue(forKey: sequence) else { return }
        pendingAcks.remove(sequence)
        let latency = timestamp.timeIntervalSince(sentAt) * 1000 // ms
        stats.lastLatencyMs = latency
        // 滑动平均
        if stats.averageLatencyMs == 0 {
            stats.averageLatencyMs = latency
        } else {
            stats.averageLatencyMs = stats.averageLatencyMs * 0.9 + latency * 0.1
        }
    }

    private func unit(for channel: UInt8) -> String {
        switch channel {
        case 1: return "km/h"      // 车速
        case 2: return "%"         // 电量
        case 3: return "km"        // 里程
        case 4: return "°C"        // 温度
        default: return ""
        }
    }

    /// 计算吞吐率（调用方周期性调用）
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
                startScanning()
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
        // 发现 Tesla 车辆，立即自动连接
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discovering
        peripheral.discoverServices([TeslaProtocol.vehicleServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error(error?.localizedDescription ?? "连接失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        state = .disconnected(error?.localizedDescription ?? "设备断开")
        connectedPeripheral = nil
        dataCharacteristic = nil
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
            peripheral.discoverCharacteristics([TeslaProtocol.dataCharacteristicUUID,
                                                TeslaProtocol.batteryUUID,
                                                TeslaProtocol.vehicleStatusUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case TeslaProtocol.dataCharacteristicUUID:
                dataCharacteristic = characteristic
                // 关键：订阅 notify，实现低延迟接收
                peripheral.setNotifyValue(true, for: characteristic)
            case TeslaProtocol.batteryUUID, TeslaProtocol.vehicleStatusUUID:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
        if dataCharacteristic != nil {
            state = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying {
            state = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        handleReceivedFrame(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // 写完成后等待 ACK 帧进行延迟测量（低延迟确认）
    }
}
