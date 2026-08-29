import Foundation
import CoreBluetooth
import Combine

/// 小智设备 BLE 配置通道
///
/// 原版工具通过 USB 串口发送文本命令（VIN/STATUS/BL/CPU/...）。
/// iOS 无 USB 主机能力，本 App 改用 BLE 的 UART 服务（可配置 UUID）
/// 传输同一条文本命令通道，实现手机端配置小智设备。
///
/// 默认使用 Nordic UART Service（被大量 ESP32 固件采用）：
///   服务  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
///   RX    6E400002-B5A3-F393-E0A9-E50E24DCCA9E  (App 写)
///   TX    6E400003-B5A3-F393-E0A9-E50E24DCCA9E  (App 读/通知)
final class BLEService: NSObject, ObservableObject {
    static let shared = BLEService()

    // BLE UART 默认 UUID（可覆盖）
    static let defaultServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let defaultRXUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let defaultTXUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Published var devices: [CBPeripheral] = []
    @Published var isScanning = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var isConnected = false
    @Published var consoleLog: String = ""

    private var centralManager: CBCentralManager!
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var serviceUUID = defaultServiceUUID
    private var rxUUID = defaultRXUUID
    private var txUUID = defaultTXUUID

    // 命令响应（串行，仅在主线程访问）
    private var responseBuffer = ""
    private var commandGeneration = 0
    private var onResponse: ((String) -> Void)?
    private var stopPattern: String?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 控制

    func startScan() {
        guard centralManager.state == .poweredOn else {
            log("蓝牙未就绪，请打开蓝牙")
            return
        }
        mainAsync { self.devices.removeAll() }
        isScanning = true
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        isScanning = false
        centralManager.stopScan()
    }

    func connect(_ peripheral: CBPeripheral) {
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let p = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(p)
    }

    func configureService(uuid: String, rx: String, tx: String) {
        serviceUUID = CBUUID(string: uuid)
        rxUUID = CBUUID(string: rx)
        txUUID = CBUUID(string: tx)
    }

    // MARK: - 命令通道

    /// 发送一行文本命令并等待匹配 stopPattern 的响应
    func sendCommand(_ line: String, stopPattern: String? = nil, timeout: TimeInterval = 6,
                     onResponse: @escaping (String) -> Void) {
        guard isConnected, let tx = txCharacteristic else {
            onResponse("未连接设备")
            return
        }
        commandGeneration += 1
        let gen = commandGeneration
        self.stopPattern = stopPattern
        self.onResponse = onResponse
        responseBuffer = ""

        let cmd = "\r\n\(line)\r\n"
        guard let data = cmd.data(using: .utf8) else { return }
        connectedPeripheral?.writeValue(data, for: tx, type: .withResponse)
        log("→ \(line)")

        // 超时兜底（仅在还没命中模式时才触发）
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.commandGeneration == gen else { return }
            guard let on = self.onResponse else { return }
            let result = self.responseBuffer
            self.onResponse = nil
            self.stopPattern = nil
            on(result.isEmpty ? "未收到固件确认（超时）" : result)
        }
    }

    /// 发送原始数据（用于 KEYBEGIN/KEYEND 私钥导入）
    func sendRaw(_ data: Data) {
        guard isConnected, let tx = txCharacteristic else { return }
        connectedPeripheral?.writeValue(data, for: tx, type: .withResponse)
    }

    /// 不发送命令，仅等待匹配 stopPattern 的响应（用于已通过 sendRaw 下发的流程）
    func waitForResponse(stopPattern: String, timeout: TimeInterval = 8,
                         onResponse: @escaping (String) -> Void) {
        guard isConnected else { onResponse("未连接设备"); return }
        commandGeneration += 1
        let gen = commandGeneration
        self.stopPattern = stopPattern
        self.onResponse = onResponse
        responseBuffer = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.commandGeneration == gen else { return }
            guard let on = self.onResponse else { return }
            let result = self.responseBuffer
            self.onResponse = nil
            self.stopPattern = nil
            on(result.isEmpty ? "未收到固件确认（超时）" : result)
        }
    }

    private func log(_ s: String) {
        mainAsync { [weak self] in
            self?.consoleLog += (self?.consoleLog.isEmpty ?? true) ? s : "\n" + s
        }
    }

    private func mainAsync(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            log("蓝牙已就绪")
        } else {
            log("蓝牙状态：\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        mainAsync {
            if !self.devices.contains(where: { $0.identifier == peripheral.identifier }) {
                self.devices.append(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        mainAsync {
            self.connectedPeripheral = peripheral
            self.isConnected = true
            self.log("已连接：\(peripheral.name ?? "小智设备")")
        }
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        mainAsync {
            self.isConnected = false
            self.connectedPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.log("已断开连接")
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == txUUID {
                txCharacteristic = c
            } else if c.uuid == rxUUID {
                rxCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let text = String(data: value, encoding: .utf8) ?? ""
        responseBuffer += text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { log("← \(trimmed)") }

        // 命中 stopPattern
        if let pat = stopPattern,
           let regex = try? NSRegularExpression(pattern: pat),
           regex.firstMatch(in: responseBuffer, range: NSRange(responseBuffer.startIndex..., in: responseBuffer)) != nil {
            let on = onResponse
            onResponse = nil
            stopPattern = nil
            commandGeneration += 1
            on?(responseBuffer)
        }
    }
}
