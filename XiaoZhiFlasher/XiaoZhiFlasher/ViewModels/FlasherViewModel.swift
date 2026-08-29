import Foundation
import Combine
import CoreBluetooth

final class FlasherViewModel: ObservableObject {
    @Published var status = DeviceStatus()
    @Published var isScanning = false
    @Published var lastMessage: String?
    @Published var lastMessageIsError = false
    @Published var consoleLog: String = ""

    // 配置项
    @Published var vinInput = ""
    @Published var privateKeyPEM = ""
    @Published var backlight = 80
    @Published var cpuMHz = 240
    @Published var blePower = 9
    @Published var rotation = 0
    @Published var dialStyle = DialStyle.combo
    @Published var demoBoot = false
    @Published var scheduleEnabled = false
    @Published var scheduleSlots: [BrightnessSlot] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        let ble = BLEService.shared
        ble.$isScanning
            .receive(on: RunLoop.main)
            .assign(to: &$isScanning)
        ble.$consoleLog
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.consoleLog = $0 }
            .store(in: &cancellables)
    }

    // MARK: - 连接

    func startScan() { BLEService.shared.startScan() }
    func stopScan() { BLEService.shared.stopScan() }

    func connect(_ peripheral: CBPeripheral) {
        BLEService.shared.stopScan()
        BLEService.shared.connect(peripheral)
    }

    func disconnect() { BLEService.shared.disconnect() }

    func refreshStatus() {
        XiaoZhiProtocol.queryStatus { [weak self] st in
            DispatchQueue.main.async {
                self?.status = st
                self?.show("已读取设备状态" + (st.vin.map { "，VIN \($0)" } ?? ""))
            }
        }
    }

    // MARK: - 命令

    func sendVIN() { send { XiaoZhiProtocol.sendVIN(vinInput, onResponse: $0) } }
    func importKey() {
        guard !privateKeyPEM.isEmpty else { show("请粘贴私钥 PEM 内容", isError: true); return }
        send { XiaoZhiProtocol.importKey(privateKeyPEM, onResponse: $0) }
    }
    func sendTRUST() { send { XiaoZhiProtocol.trust(onResponse: $0) } }
    func applyBacklight() { send { XiaoZhiProtocol.sendBacklight(backlight, onResponse: $0) } }
    func applyCPU() { send { XiaoZhiProtocol.sendCPU(cpuMHz, onResponse: $0) } }
    func applyBLEPower() { send { XiaoZhiProtocol.sendBLEPower(blePower, onResponse: $0) } }
    func applyRotation() { send { XiaoZhiProtocol.sendRotation(rotation, onResponse: $0) } }
    func applyDialStyle() { send { XiaoZhiProtocol.sendDialStyle(dialStyle, onResponse: $0) } }
    func applyDemoBoot() { send { XiaoZhiProtocol.sendDemoBoot(demoBoot, onResponse: $0) } }
    func applySchedule() {
        let slots = scheduleEnabled ? scheduleSlots : []
        send { XiaoZhiProtocol.sendBLSchedule(slots, onResponse: $0) }
    }

    /// 统一在调用方闭包内把结果派发回主线程
    private func send(_ fn: (@escaping (Bool, String) -> Void) -> Void) {
        fn { ok, msg in
            DispatchQueue.main.async { self.show(msg, isError: !ok) }
        }
    }

    // MARK: - 备份

    func doBackup() {
        guard let vin = status.vin else {
            show("设备未读到 VIN，无法备份", isError: true); return
        }
        let payload = BackupPayload(vin: vin, privateKeyPEM: privateKeyPEM, paired: status.paired)
        do {
            let data = try Backup.pack(payload)
            show("备份已生成（\(data.count) 字节）")
        } catch {
            show("备份失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func show(_ msg: String, isError: Bool = false) {
        lastMessage = msg
        lastMessageIsError = isError
    }
}
