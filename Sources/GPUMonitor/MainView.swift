import SwiftUI

/// Root of the main window: one tab per monitor.
///
/// A segmented picker rather than TabView: on recent macOS, TabView draws its tab bar into the
/// title bar, where it gets clipped.
struct MainView: View {
    enum Tab: String { case gpu, battery }

    @AppStorage("selectedTab") private var selectedTab: Tab = .gpu

    var body: some View {
        VStack(spacing: 0) {
            Picker("Monitor", selection: $selectedTab) {
                Text("GPU").tag(Tab.gpu)
                Text("Battery").tag(Tab.battery)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 10)

            switch selectedTab {
            case .gpu:     ContentView()
            case .battery: BatteryView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
