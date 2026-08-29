import Foundation

/// 小智设备命令协议
///
/// 对应原版 device.py 的串口文本命令，通过 BLE 通道传输。
/// 命令行格式与固件约定一致，固件侧做 VIN 校验、CRC、NVS 落盘。
struct XiaoZhiProtocol {
    static let cpuChoices = [240, 160, 80]
    static let rotationChoices = [0, 90, 180, 270]
    static let blePowerChoices = [9, 3, 0, -3, -9]
    static let dialStyleLabels = ["复合", "纯数字", "全模拟", "纯时间", "纯功率"]
    static let maxBLSlots = 8

    // VIN：17 位字母数字，排除易混的 I/O/Q
    static let vinRegex = try! NSRegularExpression(pattern: "^[A-HJ-NPR-Z0-9]{17}$")

    static func validVin(_ vin: String) -> Bool {
        let v = vin.trimmingCharacters(in: .whitespaces).uppercased()
        return vinRegex.firstMatch(in: v, range: NSRange(v.startIndex..., in: v)) != nil
    }

    // MARK: - 状态

    /// 读取设备状态。返回 (isOurs, version, vin, paired, linkState)
    static func queryStatus(onResponse: @escaping (DeviceStatus) -> Void) {
        let ble = BLEService.shared
        ble.sendCommand("STATUS", stopPattern: "status vin=.*?paired=\\d+.*?link=\\d+", timeout: 5) { text in
            var st = DeviceStatus()
            st.isOurs = true
            st.raw = text

            if let m = text.range(of: "TITA dashboard (\\S+)", options: .regularExpression) {
                let ver = text[m].split(separator: " ").last.map(String.init)
                st.version = ver
            }
            if let m = text.range(of: "vin=(\\S+).*?paired=(\\d+).*?link=(\\d+)", options: .regularExpression) {
                let part = String(text[m])
                let vins = part.split(separator: " ")
                for tok in vins {
                    let s = String(tok)
                    if s.hasPrefix("vin=") {
                        let v = String(s.dropFirst(4))
                        st.vin = (v == "unset" || v.isEmpty) ? nil : v
                    } else if s.hasPrefix("paired=") {
                        st.paired = s.dropFirst(7) == "1"
                    } else if s.hasPrefix("link=") {
                        st.linkState = Int(s.dropFirst(5))
                    }
                }
            }
            onResponse(st)
        }
    }

    // MARK: - VIN / 密钥 / 配对

    static func sendVIN(_ vin: String, onResponse: @escaping (Bool, String) -> Void) {
        let v = vin.trimmingCharacters(in: .whitespaces).uppercased()
        guard validVin(v) else {
            onResponse(false, "VIN 格式不合法（需 17 位，且不含 I/O/Q）")
            return
        }
        BLEService.shared.sendCommand("VIN \(v)", stopPattern: "VIN saved|invalid VIN|failed to save", timeout: 6) { text in
            if text.contains("VIN saved") { onResponse(true, "VIN 已写入，设备正在重启") }
            else if text.contains("invalid VIN") { onResponse(false, "固件判定 VIN 非法") }
            else if text.contains("failed to save") { onResponse(false, "固件写入 NVS 失败") }
            else { onResponse(false, "未收到固件确认（设备可能正在重启，可稍后重试）") }
        }
    }

    /// 私钥导入：KEYBEGIN/每行/KEYEND
    /// 全部用原始字节发送，最后 waitForResponse 等固件确认。
    static func importKey(_ pem: String, onResponse: @escaping (Bool, String) -> Void) {
        let ble = BLEService.shared
        guard ble.isConnected else { onResponse(false, "未连接设备"); return }

        // 1. 进入导入模式
        ble.sendRaw("\r\nKEYBEGIN\r\n".data(using: .utf8)!)
        // 2. 逐行发送 PEM 内容
        var keyData = Data()
        for line in pem.split(separator: "\n") {
            keyData.append(Data((line + "\r\n").utf8))
        }
        ble.sendRaw(keyData)
        // 3. 结束导入
        ble.sendRaw("KEYEND\r\n".data(using: .utf8)!)
        // 4. 等待结果
        ble.waitForResponse(stopPattern: "key imported|import failed|invalid", timeout: 8) { text in
            let ok = text.lowercased().contains("imported")
            onResponse(ok, ok ? "私钥已导入" : "私钥导入失败")
        }
    }

    /// 标记为已配对（TRUST）
    static func trust(onResponse: @escaping (Bool, String) -> Void) {
        BLEService.shared.sendCommand("TRUST", stopPattern: "marked paired", timeout: 6) { text in
            let ok = text.contains("marked paired")
            onResponse(ok, ok ? "已标记为配对并重启" : "固件未确认")
        }
    }

    // MARK: - 配置项

    static func sendBacklight(_ pct: Int, persist: Bool = true, onResponse: @escaping (Bool, String) -> Void) {
        let verb = persist ? "BL" : "BLTEST"
        BLEService.shared.sendCommand("\(verb) \(pct)", stopPattern: "applied|invalid brightness", timeout: 6) { text in
            if text.contains("invalid brightness") { onResponse(false, "固件拒绝：亮度需在 10~100 之间") }
            else if text.contains("applied") { onResponse(true, "背光已设为 \(pct)%") }
            else { onResponse(false, "未收到固件确认") }
        }
    }

    static func sendCPU(_ mhz: Int, onResponse: @escaping (Bool, String) -> Void) {
        guard cpuChoices.contains(mhz) else { onResponse(false, "CPU 频率只能是 240 / 160 / 80"); return }
        BLEService.shared.sendCommand("CPU \(mhz)", stopPattern: "applied|invalid CPU|failed to apply", timeout: 6) { text in
            if text.contains("applied") { onResponse(true, "CPU 频率已设为 \(mhz) MHz") }
            else if text.contains("invalid") { onResponse(false, "固件拒绝该频率") }
            else if text.contains("failed") { onResponse(false, "固件应用失败，未保存") }
            else { onResponse(false, "未收到固件确认") }
        }
    }

    static func sendBLEPower(_ dbm: Int, onResponse: @escaping (Bool, String) -> Void) {
        guard blePowerChoices.contains(dbm) else { onResponse(false, "蓝牙功率档位不支持"); return }
        BLEService.shared.sendCommand("BLEPWR \(dbm)", stopPattern: "applied|invalid TX power|failed to apply", timeout: 6) { text in
            if text.contains("applied") { onResponse(true, "蓝牙发射功率已设为 \(dbm) dBm") }
            else if text.contains("failed") { onResponse(false, "固件应用失败，未保存") }
            else { onResponse(false, "固件拒绝该功率档") }
        }
    }

    static func sendRotation(_ deg: Int, onResponse: @escaping (Bool, String) -> Void) {
        guard rotationChoices.contains(deg) else { onResponse(false, "方向只能是 0 / 90 / 180 / 270"); return }
        BLEService.shared.sendCommand("ROT \(deg)", stopPattern: "saved; restarting|invalid rotation|failed to save", timeout: 6) { text in
            if text.contains("restarting") { onResponse(true, "屏幕方向已设为 \(deg)°，设备正在重启") }
            else if text.contains("invalid") { onResponse(false, "固件拒绝该方向") }
            else if text.contains("failed") { onResponse(false, "固件写入失败") }
            else { onResponse(false, "未收到固件确认") }
        }
    }

    static func sendDialStyle(_ style: DialStyle, onResponse: @escaping (Bool, String) -> Void) {
        BLEService.shared.sendCommand("DIAL \(style.rawValue)", stopPattern: "saved; restarting|invalid dial|failed to save", timeout: 6) { text in
            if text.contains("restarting") { onResponse(true, "表盘样式已设为「\(style.label)」，设备正在重启") }
            else if text.contains("invalid") { onResponse(false, "固件拒绝该样式") }
            else if text.contains("failed") { onResponse(false, "固件写入失败") }
            else { onResponse(false, "未收到固件确认") }
        }
    }

    static func sendDemoBoot(_ on: Bool, onResponse: @escaping (Bool, String) -> Void) {
        BLEService.shared.sendCommand("DEMOBOOT \(on ? 1 : 0)", stopPattern: "saved=\\d", timeout: 6) { text in
            if text.contains("saved") { onResponse(true, on ? "开机自动演示已开启（重启后生效）" : "开机自动演示已关闭") }
            else { onResponse(false, "未收到固件确认") }
        }
    }

    // MARK: - 定时亮度

    static func sendBLSchedule(_ slots: [BrightnessSlot], onResponse: @escaping (Bool, String) -> Void) {
        if slots.count > maxBLSlots { onResponse(false, "最多 \(maxBLSlots) 段"); return }
        let arg = slots.isEmpty ? "off" : slots.map { "\($0.startMinutes):\($0.brightness)" }.joined(separator: ",")
        BLEService.shared.sendCommand("BLSCHED \(arg)", stopPattern: "saved=\\d|格式|failed", timeout: 6) { text in
            if text.contains("failed") { onResponse(false, "固件写入失败") }
            else if let m = text.range(of: "saved=(\\d+)", options: .regularExpression) {
                let cnt = Int(String(text[m]).dropFirst(6))
                if cnt == 0 { onResponse(true, "定时亮度已关闭") }
                else { onResponse(true, "\(cnt ?? slots.count) 段定时亮度已保存") }
            } else { onResponse(false, "未收到固件确认") }
        }
    }
}
