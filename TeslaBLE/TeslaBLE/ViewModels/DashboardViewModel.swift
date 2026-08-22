import Foundation
import Combine

/// 仪表盘视图模型：编排蓝牙服务、汇总统计、驱动 UI
final class DashboardViewModel: ObservableObject {

    @Published var connectionState: BLEConnectionState = .idle
    @Published var samples: [TelemetrySample] = []
    @Published var stats = TransferStats()
    @Published var vehicleStatus = VehicleStatus()
    @Published var isLowLatencyMode = true

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

        // 周期更新吞吐率
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.bluetooth.updateThroughput(elapsed: 1.0)
        }
    }

    func start() {
        bluetooth.startScanning()
    }

    func stop() {
        bluetooth.disconnect()
    }

    /// 发送一条遥测数据（模拟车辆数据下行 / 测试发送）
    func sendDemoData() {
        guard connectionState.isConnected else { return }
        let value = Double.random(in: 0...100)
        bluetooth.sendTelemetry(channel: 1, value: value)
    }

    /// 发送自定义字符串负载
    func sendText(_ text: String) {
        let payload = Array(text.utf8)
        bluetooth.send(command: .control, payload: payload)
    }

    private func updateVehicleStatus(from samples: [TelemetrySample]) {
        // 从最近样本中提取车辆状态（channel 1=车速 2=电量 3=里程 4=温度）
        var status = VehicleStatus()
        for sample in samples.suffix(20) {
            switch sample.channel {
            case "ch1": status.speedKmh = sample.value
            case "ch2": status.batteryPercent = Int(sample.value)
            case "ch3": status.odometerKm = sample.value
            case "ch4": status.temperatureC = sample.value
            default: break
            }
        }
        status.state = connectionState.isConnected ? "connected" : "idle"
        vehicleStatus = status
    }

    deinit {
        throughputTimer?.invalidate()
    }
}
