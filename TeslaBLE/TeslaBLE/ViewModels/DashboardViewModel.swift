import Foundation
import Combine

/// 仪表盘视图模型：编排蓝牙服务、汇总统计、驱动 UI
final class DashboardViewModel: ObservableObject {

    @Published var connectionState: BLEConnectionState = .idle
    @Published var samples: [TelemetrySample] = []
    @Published var stats = TransferStats()
    @Published var vehicleStatus = VehicleStatus()
    @Published var isLowLatencyMode = true
    @Published var isAuthenticated = false
    @Published var sessionStageText = "未连接"

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

    func start() {
        bluetooth.startScanning(vehicleName: nil)
    }

    func stop() {
        bluetooth.disconnect()
    }

    /// 设置车辆 VIN（用于命令个性化签名，必需）
    func setVIN(_ vin: String) {
        bluetooth.vin = vin
    }

    /// 发送控制命令
    func sendCommand(_ command: VehicleControlCommand) {
        guard connectionState.isConnected else { return }
        switch command {
        case .lock:
            bluetooth.sendLockCommand()
        case .unlock:
            bluetooth.sendUnlockCommand()
        case .honk:
            bluetooth.sendHonkCommand()
        case .flash:
            bluetooth.sendFlashCommand()
        case .status:
            bluetooth.requestVehicleStatus()
        }
    }

    /// 发送一条遥测数据（测试用）
    func sendDemoData() {
        guard connectionState.isConnected else { return }
        let value = Double.random(in: 0...100)
        bluetooth.sendTelemetry(channel: 1, value: value)
    }

    /// 发送自定义文本负载
    func sendText(_ text: String) {
        let payload = Array(text.utf8)
        bluetooth.sendCustomData(payload)
    }

    /// 触发白名单配对
    func startWhitelist() {
        bluetooth.startWhitelist()
    }

    /// 重置密钥
    func resetKeys() {
        bluetooth.resetKeys()
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
        status.chargePortOpen = state.chargePortOpen
        status.charging = state.charging
        status.climateOn = state.climateOn
        status.sentryMode = state.sentryMode
        status.state = connectionState.isConnected ? "connected" : "idle"
        vehicleStatus = status
    }

    private func updateVehicleStatus(from samples: [TelemetrySample]) {
        // 从最近样本中提取车辆状态（channel 1=车速 2=电量 3=里程 4=温度）
        var status = vehicleStatus
        for sample in samples.suffix(20) {
            switch sample.channel {
            case "ch1": status.speedKmh = sample.value
            case "ch2": status.batteryPercent = Int(sample.value)
            case "ch3": status.odometerKm = sample.value
            case "ch4": status.temperatureC = sample.value
            default: break
            }
        }
        vehicleStatus = status
    }

    deinit {
        throughputTimer?.invalidate()
    }
}
