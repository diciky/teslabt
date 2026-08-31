import SwiftUI
import UIKit

struct BackupView: View {
    @ObservedObject var vm: FlasherViewModel
    @State private var showShare = false
    @State private var backupData: Data?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("用户数据备份")) {
                    Text("备份 VIN、私钥与配对标志。私钥是唯一不可再生的部分——它对应的公钥在车辆白名单里。")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("VIN")
                        Spacer()
                        Text(vm.status.vin ?? "未读取到")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("配对")
                        Spacer()
                        Text(vm.status.paired ? "是" : "否")
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("生成备份 (.bin)") {
                        vm.doBackup()
                        if let vin = vm.status.vin {
                            let payload = BackupPayload(vin: vin, privateKeyPEM: vm.privateKeyPEM, paired: vm.status.paired)
                            backupData = try? Backup.pack(payload)
                            if backupData != nil { showShare = true }
                        }
                    }
                }

                Section(header: Text("固件刷写")) {
                    Text("iOS 无 USB 主机能力，无法像 PC 版那样通过 esptool 刷写 bootloader / 固件。若你的小智固件内置 BLE OTA 服务，请通过对应的固件升级通道刷写。")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
            .navigationTitle("备份与刷机")
            .sheet(isPresented: $showShare) {
                if let data = backupData {
                    ShareSheet(items: [data])
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
