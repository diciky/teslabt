import SwiftUI

struct ConsoleView: View {
    @ObservedObject var vm: FlasherViewModel

    var body: some View {
        NavigationView {
            ScrollView {
                Text(vm.consoleLog.isEmpty ? "暂无日志" : vm.consoleLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("通信日志")
        }
    }
}
