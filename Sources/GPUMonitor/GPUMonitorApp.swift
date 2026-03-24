import SwiftUI

@main
struct GPUMonitorApp: App {
    // Single shared data source — used by both the main window and the menu bar item.
    @StateObject private var gpu = GPUDataSource()
    @AppStorage("isDarkMode") private var isDarkMode = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(gpu)
                .preferredColorScheme(isDarkMode ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 300)

        MenuBarExtra {
            Button("Show Window") {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows { w.makeKeyAndOrderFront(nil) }
            }
            Divider()
            Toggle("Dark Mode", isOn: $isDarkMode)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            MenuBarLabel(load: gpu.current)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The small view rendered inside the macOS menu bar.
struct MenuBarLabel: View {
    let load: Double

    var body: some View {
        HStack(spacing: 5) {
            // Vertical bar — height proportional to load, color-coded
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.15))
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor)
                    .frame(height: barHeight)
            }
            .frame(width: 4, height: 14)
            .animation(.linear(duration: 0.4), value: load)

            // Fixed-width text: "%3.0f%%" left-pads with spaces so
            // "  9%", " 42%", "100%" are all the same width in monospaced.
            Text(String(format: "%3.0f%%", load))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.primary)
    }

    private var barHeight: CGFloat { CGFloat(max(1, load / 100.0) * 14) }

    private var barColor: Color {
        switch load {
        case ..<40:  return .green
        case ..<70:  return .yellow
        default:     return .red
        }
    }
}
