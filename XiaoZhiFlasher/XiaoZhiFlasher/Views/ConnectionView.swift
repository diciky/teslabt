import SwiftUI

struct ConnectionView: View {
    @ObservedObject var vm: FlasherViewModel
    @ObservedObject private var ble = BLEService.shared
    @State private var serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    @State private var rxUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    @State private var txUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    @State private var showUUIDConfig = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("小智设备")) {
                    HStack {
                        Circle()
                            .fill(vm.status.isConnected ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(vm.status.isConnected ? "已连接" : "未连接")
                            .bold()
                        Spacer()
                        if vm.isScanning {
                            ProgressView()
                                .padding(.trailing, 8)
                            Button("停止") { vm.stopScan() }
                        } else {
                            Button("扫描") { vm.startScan() }
                        }
                    }

                    ForEach(ble.devices, id: \.identifier) { peripheral in
                        Button {
                            vm.connect(peripheral)
                        } label: {
                            HStack {
                                Text(peripheral.name ?? "未命名设备")
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("连接")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    if vm.status.isConnected {
                        Button("断开") { vm.disconnect() }
                            .foregroundColor(.red)

                        Button("读取状态") { vm.refreshStatus() }
                    }
                }

                if vm.status.isConnected {
                    Section(header: Text("设备信息")) {
                        LabeledContent("固件版本", value: vm.status.version ?? "—")
                        LabeledContent("VIN", value: vm.status.vin ?? "未设置")
                        LabeledContent("配对", value: vm.status.paired ? "是" : "否")
                        if let link = vm.status.linkState {
                            LabeledContent("链路状态", value: "\(link)")
                        }
                    }
                }

                Section(header: Text("BLE 服务 UUID")) {
                    Button("配置服务 UUID") { showUUIDConfig.toggle() }
                        .sheet(isPresented: $showUUIDConfig) {
                            UUIDConfigView(service: $serviceUUID, rx: $rxUUID, tx: $txUUID)
                        }
                }
            }
            .navigationTitle("小智 Flasher")
        }
    }
}

struct UUIDConfigView: View {
    @Binding var service: String
    @Binding var rx: String
    @Binding var tx: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("默认 Nordic UART 服务")) {
                    TextField("Service UUID", text: $service)
                    TextField("RX（写）UUID", text: $rx)
                    TextField("TX（读）UUID", text: $tx)
                }
                Section {
                    Button("应用并重扫") {
                        BLEService.shared.configureService(uuid: service, rx: rx, tx: tx)
                        dismiss()
                    }
                }
            }
            .navigationTitle("BLE UUID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
