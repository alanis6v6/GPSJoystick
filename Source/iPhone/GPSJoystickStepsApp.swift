import SwiftUI

@main
struct GPSJoystickStepsApp: App {
    var body: some Scene {
        WindowGroup {
            StepSyncView()
        }
    }
}

private struct StepSyncView: View {
    @StateObject private var receiver = StepReceiver()

    var body: some View {
        NavigationStack {
            Form {
                Section("模擬步數") {
                    LabeledContent("本次開啟已寫入", value: "\(receiver.savedSteps) 步")
                    Text(receiver.status)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("step-sync-status")
                    if receiver.active {
                        Button("停止同步", action: receiver.stop)
                    } else {
                        Button("開始同步") {
                            Task {
                                await receiver.start()
                            }
                        }
                        .disabled(receiver.authorizing || receiver.saving)
                    }
                }
                Section {
                    Text("連線後可切換到其他 App。若強制關閉此 App，請重新開啟並開始同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("GPS 搖桿步數")
        }
    }
}
