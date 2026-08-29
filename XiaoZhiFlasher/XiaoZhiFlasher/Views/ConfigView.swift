import SwiftUI

struct ConfigView: View {
    @ObservedObject var vm: FlasherViewModel

    var body: some View {
        NavigationView {
            Form {
                // 身份
                Section(header: Text("车辆身份")) {
                    TextField("VIN（17 位，不含 I/O/Q）", text: $vm.vinInput)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    Button("写入 VIN") { vm.sendVIN() }
                    Button("标记为已配对 (TRUST)") { vm.sendTRUST() }
                }

                Section(header: Text("私钥导入")) {
                    TextEditor(text: $vm.privateKeyPEM)
                        .frame(minHeight: 80)
                        .font(.system(.caption, design: .monospaced))
                    Button("导入私钥") { vm.importKey() }
                }

                // 显示与性能
                Section(header: Text("显示")) {
                    Picker("背光亮度", selection: $vm.backlight) {
                        ForEach(Array(stride(from: 10, through: 100, by: 10)), id: \.self) {
                            Text("\($0)%").tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("应用背光") { vm.applyBacklight() }

                    Picker("屏幕方向", selection: $vm.rotation) {
                        Text("0°").tag(0)
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                    .pickerStyle(.menu)
                    Button("应用方向") { vm.applyRotation() }

                    Picker("表盘样式", selection: $vm.dialStyle) {
                        ForEach(DialStyle.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("应用表盘样式") { vm.applyDialStyle() }
                }

                Section(header: Text("性能与功耗")) {
                    Picker("CPU 频率", selection: $vm.cpuMHz) {
                        Text("240 MHz").tag(240)
                        Text("160 MHz").tag(160)
                        Text("80 MHz").tag(80)
                    }
                    .pickerStyle(.menu)
                    Button("应用 CPU") { vm.applyCPU() }

                    Picker("蓝牙发射功率", selection: $vm.blePower) {
                        Text("9 dBm（最高）").tag(9)
                        Text("3 dBm").tag(3)
                        Text("0 dBm").tag(0)
                        Text("-3 dBm").tag(-3)
                        Text("-9 dBm").tag(-9)
                    }
                    .pickerStyle(.menu)
                    Button("应用蓝牙功率") { vm.applyBLEPower() }
                }

                Section(header: Text("开机与定时")) {
                    Toggle("开机自动演示", isOn: $vm.demoBoot)
                        .onChange(of: vm.demoBoot) { _ in vm.applyDemoBoot() }

                    Toggle("启用定时亮度", isOn: $vm.scheduleEnabled)
                    if vm.scheduleEnabled {
                        ForEach($vm.scheduleSlots) { $slot in
                            HStack {
                                Text("\(slot.startMinutes / 60):\(String(format: "%02d", slot.startMinutes % 60))")
                                Spacer()
                                Text("\(slot.brightness)%")
                            }
                        }
                        Button("添加时段") {
                            vm.scheduleSlots.append(BrightnessSlot(startMinutes: 0, brightness: 50))
                        }
                        Button("应用定时") { vm.applySchedule() }
                    }
                }

                // 消息
                if let msg = vm.lastMessage {
                    Section {
                        Text(msg)
                            .foregroundColor(vm.lastMessageIsError ? .red : .green)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("设备配置")
        }
    }
}
