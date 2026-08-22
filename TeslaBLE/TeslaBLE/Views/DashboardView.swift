import SwiftUI

/// 主仪表盘：连接控制 + 车辆状态 + 低延迟收发统计 + 实时数据流
struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                connectionHeader
                vehicleStatusCard
                transferStatsCard
                lowLatencyControls
                liveDataList
            }
            .padding()
            .navigationTitle("Tesla BLE 低延迟通信")
        }
    }

    // MARK: - 连接区
    private var connectionHeader: some View {
        HStack {
            Circle()
                .fill(viewModel.connectionState.isConnected ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
            Text(viewModel.connectionState.label)
                .font(.headline)
            Spacer()
            if !viewModel.connectionState.isConnected {
                Button("扫描连接") { viewModel.start() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("断开") { viewModel.stop() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 车辆状态
    private var vehicleStatusCard: some View {
        HStack(spacing: 12) {
            VStack {
                Text("\(Int(viewModel.vehicleStatus.speedKmh))")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.blue)
                Text("km/h 车速").font(.caption)
            }
            .frame(maxWidth: .infinity)

            VStack {
                Text("\(viewModel.vehicleStatus.batteryPercent)%")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.green)
                Text("电量").font(.caption)
            }
            .frame(maxWidth: .infinity)

            VStack {
                Text("\(String(format: "%.1f", viewModel.vehicleStatus.odometerKm))")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.orange)
                Text("里程 km").font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 传输统计
    private var transferStatsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("低延迟传输统计").font(.headline)
            HStack {
                statItem(title: "平均延迟", value: String(format: "%.1f ms", viewModel.stats.averageLatencyMs))
                statItem(title: "最近延迟", value: String(format: "%.1f ms", viewModel.stats.lastLatencyMs))
            }
            HStack {
                statItem(title: "吞吐率", value: String(format: "%.0f B/s", viewModel.stats.throughputBytesPerSec))
                statItem(title: "接收包", value: "\(viewModel.stats.packetsReceived)")
            }
            HStack {
                statItem(title: "发送包", value: "\(viewModel.stats.packetsSent)")
                statItem(title: "丢包率", value: String(format: "%.1f%%", viewModel.stats.packetLossRate))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控制区
    private var lowLatencyControls: some View {
        HStack(spacing: 12) {
            Toggle("低延迟模式", isOn: $viewModel.isLowLatencyMode)
                .toggleStyle(.switch)
                .labelsHidden()
            Text("低延迟模式").font(.subheadline)
            Spacer()
            Button("发送测试数据") { viewModel.sendDemoData() }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.connectionState.isConnected)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 实时数据流
    private var liveDataList: some View {
        List {
            Section("实时数据流") {
                ForEach(viewModel.samples.reversed()) { sample in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(sample.channel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(sample.value, specifier: "%.2f") \(sample.unit)")
                                .font(.body)
                        }
                        Spacer()
                        Text(sample.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(sample.rawPayload)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
