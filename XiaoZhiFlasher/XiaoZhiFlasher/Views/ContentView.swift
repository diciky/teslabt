import SwiftUI

struct ContentView: View {
    @StateObject private var vm = FlasherViewModel()

    var body: some View {
        TabView {
            ConnectionView(vm: vm)
                .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
            ConfigView(vm: vm)
                .tabItem { Label("配置", systemImage: "slider.horizontal.3") }
            BackupView(vm: vm)
                .tabItem { Label("备份", systemImage: "externaldrive") }
            ConsoleView(vm: vm)
                .tabItem { Label("日志", systemImage: "terminal") }
        }
    }
}
