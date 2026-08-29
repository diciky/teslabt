import SwiftUI

/// 精简版主界面：横向布局，聚焦蓝牙接收车机数据展示
/// - 顶部：设备识别信息（固件版本、VIN、配对标志、链路状态）
/// - 中部：实时车机数据（大数字横向排列）
/// - 底部：身份配置（VIN 写入、私钥导入、TRUST 配对）
/// - 横向展示：无需表盘
struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showingIdentityConfig = false
    @State private var showResetKeysAlert = false

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height

                if isLandscape {
                    // 横向布局：左右分区
                    HStack(spacing: 12) {
                        // 左侧：连接+设备识别
                        VStack(alignment: .leading, spacing: 8) {
                            connectionHeader
                            deviceInfoCard
                            identityConfigButton
                            Spacer()
                        }
                        .frame(width: geo.size.width * 0.32)
                        .padding(.leading, 12)
                        .padding(.vertical, 8)

                        // 右侧：实时数据展示
                        VStack(spacing: 8) {
                            vehicleDataCard
                            liveDataRow
                        }
                        .padding(.trailing, 12)
                        .padding(.vertical, 8)
                    }
                } else {
                    // 纵向布局：上下排列
                    ScrollView {
                        VStack(spacing: 16) {
                            connectionHeader
                            deviceInfoCard
                            vehicleDataCard
                            liveDataRow
                            identityConfigButton
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Tesla 蓝牙数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.connectionState.isConnected {
                        Button(action: {
                            viewModel.refreshData()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingIdentityConfig) {
                IdentityConfigView(viewModel: viewModel)
            }
            .alert("配对状态", isPresented: $viewModel.showPairingAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.pairingMessage)
            }
            .alert("重置密钥", isPresented: $showResetKeysAlert) {
                Button("确认重置", role: .destructive) { viewModel.resetKeys() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("重置后将丢失所有密钥和配对信息，需重新在车内进行 TRUST 配对。")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // 如果已有 VIN 则自动填充
            if !viewModel.bluetooth.vin.isEmpty {
                viewModel.vinInput = viewModel.bluetooth.vin
            }
        }
    }

    // MARK: - 连接控制区
    private var connectionHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(viewModel.connectionState.isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(viewModel.connectionState.label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if !viewModel.connectionState.isConnected {
                    Button("扫描连接") { viewModel.start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("断开") { viewModel.stop() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if viewModel.isAuthenticated {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                    Text("已认证 · 会话加密已启用")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            } else if viewModel.connectionState.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                    Text("未认证 · 需要 TRUST 配对")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 设备识别卡片
    private var deviceInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设备识别")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            deviceInfoRow(label: "固件版本", value: viewModel.deviceInfo.firmwareVersion)
            deviceInfoRow(label: "VIN", value: viewModel.deviceInfo.vin.isEmpty ? "未设置" : viewModel.deviceInfo.vin)
            deviceInfoRow(label: "配对标志", value: viewModel.deviceInfo.isPaired ? "✅ 已配对" : "❌ 未配对",
                          valueColor: viewModel.deviceInfo.isPaired ? .green : .red)
            deviceInfoRow(label: "链路状态", value: viewModel.deviceInfo.linkState,
                          valueColor: viewModel.connectionState.isConnected ? .blue : .secondary)
            deviceInfoRow(label: "设备名称", value: viewModel.deviceInfo.vehicleName.isEmpty ? "—" : viewModel.deviceInfo.vehicleName)
            deviceInfoRow(label: "信号强度", value: viewModel.deviceInfo.rssi == 0 ? "—" : "\(viewModel.deviceInfo.rssi) dBm")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }

    private func deviceInfoRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
                .lineLimit(1)
        }
    }

    // MARK: - 实时车机数据卡片（横向大数字展示）
    private var vehicleDataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时车机数据")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            // 大数字横向排列：速度 / 电量 / 里程
            HStack(spacing: 16) {
                metricCard(
                    value: String(format: "%.0f", viewModel.vehicleStatus.speedKmh),
                    unit: "km/h",
                    label: "车速",
                    color: .blue
                )
                metricCard(
                    value: "\(viewModel.vehicleStatus.batteryPercent)",
                    unit: "%",
                    label: "电量",
                    color: .green
                )
                metricCard(
                    value: String(format: "%.1f", viewModel.vehicleStatus.odometerKm),
                    unit: "km",
                    label: "里程",
                    color: .orange
                )
            }

            // 状态标签行
            HStack(spacing: 12) {
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

            // 传输统计（精简）
            HStack(spacing: 12) {
                smallStat(title: "接收包", value: "\(viewModel.stats.packetsReceived)")
                smallStat(title: "接收字节", value: "\(viewModel.stats.totalBytesReceived)")
                smallStat(title: "吞吐", value: String(format: "%.0f B/s", viewModel.stats.throughputBytesPerSec))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }

    private func metricCard(value: String, unit: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(color)
            HStack(spacing: 2) {
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
    }

    private func statusBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func smallStat(title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 实时数据流
    private var liveDataRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("实时数据流")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.samples.count) 条")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if viewModel.samples.isEmpty {
                Text("等待接收数据…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.samples.suffix(20).reversed()) { sample in
                            HStack {
                                Text(sample.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(sample.channel)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(sample.rawPayload)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - 身份配置入口
    private var identityConfigButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("身份配置")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)

            Button(action: { showingIdentityConfig = true }) {
                HStack {
                    Image(systemName: "key.fill")
                    Text("VIN 写入 / 私钥导入 / TRUST 配对")
                        .font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
            }
            .buttonStyle(.plain)

            // 重置密钥
            Button(action: { showResetKeysAlert = true }) {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("重置密钥")
                        .font(.caption)
                    Spacer()
                }
                .padding(10)
                .foregroundColor(.red)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemBackground)))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
    }
}

// MARK: - 身份配置 Sheet
struct IdentityConfigView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("VIN 写入")) {
                    TextField("输入 17 位 VIN（不含 I/O/Q）", text: $viewModel.vinInput)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.allCharacters)
                        .autocorrectionDisabled()
                        .onChange(of: viewModel.vinInput) { _ in
                            viewModel.vinInput = viewModel.vinInput.uppercased()
                        }
                    if let error = viewModel.vinError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("保存 VIN") { viewModel.saveVIN() }
                        .disabled(viewModel.vinInput.isEmpty)
                }

                Section(header: Text("私钥导入")) {
                    TextEditor(text: $viewModel.privateKeyInput)
                        .frame(minHeight: 100)
                        .font(.caption.monospaced())
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(.systemGray4), lineWidth: 1)
                        )
                    Text("支持 PEM 格式（KEYBEGIN...KEYEND 包裹）")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let error = viewModel.keyImportError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("导入私钥") { viewModel.importKey() }
                        .disabled(viewModel.privateKeyInput.isEmpty)
                }

                Section(header: Text("TRUST 配对")) {
                    Button {
                        viewModel.startPairing()
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.key")
                            Text("发起 TRUST 配对")
                        }
                    }
                    .disabled(!viewModel.connectionState.isConnected)
                    Text("配对需要已连接的车辆和在车内中控屏确认。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("身份配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}
