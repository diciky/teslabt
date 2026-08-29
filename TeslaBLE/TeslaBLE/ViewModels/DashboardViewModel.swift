import Foundation
import Combine

/// 精简版视图模型：聚焦蓝牙接收车机数据
final class DashboardViewModel: ObservableObject {

    @Published var connectionState: BLEConnectionState = .idle
    @Published var samples: [TelemetrySample] = []
    @Published var stats = TransferStats()
    @Published var deviceInfo = DeviceInfo()
    @Published var vehicleStatus = VehicleStatus()
    @Published var isAuthenticated = false
    @Published var sessionStageText = "未连接"
    @Published var vinInput: String = ""
    @Published var privateKeyInput: String = ""
    @Published var vinError: String?
    @Published var keyImportError: String?
    @Published var showPairingAlert = false
    @Published var pairingMessage: String = ""

    let bluetooth = BLEService()

    private var cancellables = Set<AnyCancellable>()
    private var throughputTimer: Timer?

    init() {
        // 订阅蓝牙状态
        bluetooth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)

        // 订阅设备信息
        bluetooth.$deviceInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.deviceInfo = info
            }
            .store(in: &cancellables)

        // 订阅收到的遥测样本
        bluetooth.$receivedSamples
            .receive(on: DispatchQueue.main)
            .sink { [weak self] samples in
                self?.samples = samples
                self?.updateVehicleStatus(from: samples)
            }
            .store(in: &cancellables)

        bluetooth.$stats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stats in
                self?.stats = stats
            }
            .store(in: &cancellables)

        // 订阅车辆状态
        bluetooth.$vehicleState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.syncVehicleState(state)
            }
            .store(in: &cancellables)

        // 订阅认证状态
        bluetooth.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] auth in
                self?.isAuthenticated = auth
            }
            .store(in: &cancellables)

        // 订阅会话阶段
        bluetooth.$sessionStage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                self?.sessionStageText = self?.stageText(stage) ?? ""
            }
            .store(in: &cancellables)

        // 周期更新吞吐率
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.bluetooth.updateThroughput(elapsed: 1.0)
        }
    }

    // MARK: - 连接控制

    func start() {
        bluetooth.startScanning(vehicleName: nil)
    }

    func stop() {
        bluetooth.disconnect()
    }

    // MARK: - 身份配置

    /// 写入 VIN（验证后保存）
    func saveVIN() {
        let result = bluetooth.setVIN(vinInput)
        switch result {
        case .success(let validVIN):
            vinInput = validVIN
            vinError = nil
            deviceInfo.vin = validVIN
        case .failure(let error):
            vinError = error
        }
    }

    /// 导入私钥
    func importKey() {
        guard !privateKeyInput.isEmpty else {
            keyImportError = "请粘贴私钥内容"
            return
        }
        let result = bluetooth.importPrivateKey(privateKeyInput)
        switch result {
        case .success:
            keyImportError = nil
            privateKeyInput = ""
            pairingMessage = "私钥导入成功"
            showPairingAlert = true
        case .failure(let error):
            keyImportError = error
        }
    }

    /// TRUST 配对
    func startPairing() {
        bluetooth.startWhitelist()
    }

    /// 重置密钥
    func resetKeys() {
        bluetooth.resetKeys()
        pairingMessage = "密钥已重置，需重新配对"
        showPairingAlert = true
    }

    /// 请求车辆数据刷新
    func refreshData() {
        bluetooth.requestVehicleStatus()
        bluetooth.requestVehicleInfo()
    }

    // MARK: - 私有方法

    private func stageText(_ stage: TeslaProtocol.SessionStage) -> String {
        switch stage {
        case .idle: return "未连接"
        case .awaitingVehiclePublicKey: return "等待车辆公钥…"
        case .awaitingSessionInfo: return "等待会话信息…"
        case .authenticated: return "已认证 ✓"
        }
    }

    private func syncVehicleState(_ state: TeslaProtocol.TeslaVehicleState) {
        var status = vehicleStatus
        status.batteryPercent = state.batteryLevel
        status.locked = state.locked
        status.speedKmh = state.speedKmh
        status.odometerKm = state.odometerKm
        status.chargePortOpen = state.chargePortOpen
        status.charging = state.charging
        status.climateOn = state.climateOn
        status.sentryMode = state.sentryMode
        status.state = connectionState.isConnected ? "connected" : "idle"
        vehicleStatus = status
    }

    private func updateVehicleStatus(from samples: [TelemetrySample]) {
        var status = vehicleStatus
        for sample in samples.suffix(20) {
            switch sample.channel {
            case "ch1": status.speedKmh = sample.value
            case "ch2": status.batteryPercent = Int(sample.value)
            case "ch3": status.odometerKm = sample.value
            case "ch4": status.insideTemp = sample.value
            default: break
            }
        }
        vehicleStatus = status
    }

    deinit {
        throughputTimer?.invalidate()
    }
}
