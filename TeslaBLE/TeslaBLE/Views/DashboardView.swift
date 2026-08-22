import SwiftUI

/// 主仪表盘：连接控制 + 车辆状态 + 控制命令 + 低延迟收发统计 + 实时数据流
struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showWhitelistAlert = false
    @State private var showResetKeysAlert = false
    @State private var vinInput: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    connectionHeader
                    vehicleStatusCard
                    vehicleControlCard
                    transferStatsCard
                    lowLatencyControls
                    liveDataList
                }
                .padding()
            }
            .navigationTitle("Tesla BLE 通信")
            .alert("白名单配对", isPresented: $showWhitelistAlert) {
                Button("开始配对") { viewModel.startWhitelist() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将公钥添加到车辆白名单。请在车辆中控屏确认配对。")
            }
            .alert("重置密钥", isPresented: $showResetKeysAlert) {
                Button("确认重置", role: .destructive) { viewModel.resetKeys() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("重置后将丢失密钥，需重新在车内进行白名单配对。")
            }
        }
    }

    // MARK: - 连接区
    private var connectionHeader: some View {
        VStack(spacing: 8) {
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

            // VIN 输入（用于命令个性化签名）
            HStack {
                TextField("车辆 VIN（个性化签名必需）", text: $vinInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .autocapitalization(.allCharacters)
                    .onSubmit {
                        viewModel.setVIN(vinInput.uppercased())
                    }
                Button("保存") {
                    viewModel.setVIN(vinInput.uppercased())
                    vinInput = ""
                }
                .font(.caption)
            }

            if viewModel.isAuthenticated {
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("已认证 · 会话加密已启用")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    Button("重新配对") { showWhitelistAlert = true }
                        .font(.caption)
                    Button("重置密钥") { showResetKeysAlert = true }
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } else if viewModel.connectionState.isConnected {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                    Text("未认证 · 需要白名单配对")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("开始配对") { showWhitelistAlert = true }
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 车辆状态
    private var vehicleStatusCard: some View {
        VStack(spacing: 12) {
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

            // 附加状态
            HStack(spacing: 16) {
                statusBadge(icon: viewModel.vehicleStatus.locked ? "lock.fill" : "lock.open",
                            text: viewModel.vehicleStatus.locked ? "已锁" : "已解锁",
                            color: viewModel.vehicleStatus.locked ? .blue : .green)
                statusBadge(icon: viewModel.vehicleStatus.charging ? "bolt.fill" : "bolt.slash",
                            text: viewModel.vehicleStatus.charging ? "充电中" : "未充电",
                            color: viewModel.vehicleStatus.charging ? .green : .gray)
                statusBadge(icon: viewModel.vehicleStatus.climateOn ? "snowflake" : "thermometer",
                            text: viewModel.vehicleStatus.climateOn ? "空调开" : "空调关",
                            color: viewModel.vehicleStatus.climateOn ? .cyan : .gray)
                statusBadge(icon: viewModel.vehicleStatus.sentryMode ? "eye.fill" : "eye.slash",
                            text: viewModel.vehicleStatus.sentryMode ? "哨兵开" : "哨兵关",
                            color: viewModel.vehicleStatus.sentryMode ? .purple : .gray)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private func statusBadge(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 车辆控制
    private var vehicleControlCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("车辆控制").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(VehicleControlCommand.allCases) { command in
                    Button {
                        viewModel.sendCommand(command)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: command.icon)
                                .font(.title3)
                            Text(command.rawValue)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(.tertiarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.connectionState.isConnected)
                    .opacity(viewModel.connectionState.isConnected ? 1.0 : 0.4)
                }
            }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("实时数据流").font(.headline)
            if viewModel.samples.isEmpty {
                Text("等待接收数据…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(viewModel.samples.suffix(20).reversed()) { sample in
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
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
