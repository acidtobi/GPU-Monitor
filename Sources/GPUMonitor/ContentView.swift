import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var gpu: GPUDataSource

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                // ── Left: chart + time axis ──────────────────────────────────
                VStack(spacing: 0) {
                    chartArea
                    timeAxis
                }
                // ── Right: process legend ────────────────────────────────────
                if !gpu.topProcessNames.isEmpty {
                    Divider()
                    legendPanel
                }
            }
        }
        .frame(minWidth: 500, minHeight: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(.secondary)
            Text(gpu.gpuName)
                .font(.headline)
            Spacer()
            Stepper(value: $gpu.sampleIntervalMs, in: 100...2000, step: 100) {
                Text(intervalLabel(gpu.sampleIntervalMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("GPU Load")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", gpu.current))
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(loadColor(gpu.current))
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Chart

    private var chartArea: some View {
        ZStack {
            GridLines()
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)

            Canvas { ctx, size in drawStacked(ctx: ctx, size: size) }

            if gpu.topProcessNames.isEmpty {
                Text(gpu.permissionDenied ? "Run with sudo for per-process data" : "Collecting data…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(minHeight: 100)
    }

    // MARK: - Time axis

    private var timeAxis: some View {
        HStack {
            Text("−2 min")
            Spacer()
            Text("−1 min")
            Spacer()
            Text("now")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Legend panel (right side)

    private var legendPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                // Header row
                GridRow {
                    Color.clear.frame(width: 10, height: 1)
                    Text("Process")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("GPU %")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }

                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                    .gridCellColumns(3)

                ForEach(legendRows, id: \.name) { row in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(row.color)
                            .frame(width: 10, height: 10)
                        Text(row.name)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f%%", row.percent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 170, maxWidth: 220)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private struct LegendRow {
        let name: String
        let color: Color
        let percent: Double
    }

    private var legendRows: [LegendRow] {
        gpu.topProcessNames.map { name in
            LegendRow(name: name,
                      color: paletteColor(for: name),
                      percent: currentPercent(for: name))
        }
    }

    // MARK: - Stacked drawing

    private func drawStacked(ctx: GraphicsContext, size: CGSize) {
        let h = gpu.history
        guard h.count > 1 else { return }
        let names = gpu.topProcessNames
        let windowSecs = Double(GPUDataSource.windowMs) / 1000.0
        let now = h.last!.timestamp  // treat the newest sample as the right edge

        // Convert a snapshot's timestamp to an x coordinate.
        func xFor(_ snap: GPUSnapshot) -> CGFloat {
            let age = now.timeIntervalSince(snap.timestamp)
            return CGFloat((1.0 - age / windowSecs)) * size.width
        }

        func cumulative(_ snap: GPUSnapshot, upTo count: Int) -> Double {
            names.prefix(count).reduce(0.0) { acc, n in
                acc + (snap.processes.first(where: { $0.name == n })?.gpuPercent ?? 0)
            }
        }

        // Bucket samples by integer pixel column; last sample in chronological order wins.
        // Working in pixel space (not sample space) means no fractional-pixel drift can
        // cause points to appear or disappear between redraws.
        let pixelWidth = max(1, Int(size.width))
        var buckets: [Int: GPUSnapshot] = [:]
        for snap in h {
            let px = Int(xFor(snap))
            guard px >= 0 && px < pixelWidth else { continue }
            buckets[px] = snap  // later samples overwrite earlier ones
        }
        let renderSnaps: [(x: CGFloat, snap: GPUSnapshot)] = buckets
            .sorted { $0.key < $1.key }
            .map { (CGFloat($0.key), $0.value) }
        guard renderSnaps.count > 1 else { return }

        for (pi, name) in names.enumerated() {
            var topPts: [CGPoint] = []
            var botPts: [CGPoint] = []
            for (x, snap) in renderSnaps {
                let cumTop = min(cumulative(snap, upTo: pi + 1), 100)
                let cumBot = min(cumulative(snap, upTo: pi),     100)
                topPts.append(CGPoint(x: x, y: size.height - CGFloat(cumTop / 100) * size.height))
                botPts.append(CGPoint(x: x, y: size.height - CGFloat(cumBot / 100) * size.height))
            }
            guard topPts.count > 1 else { continue }
            var path = Path()
            path.move(to: topPts[0])
            topPts.dropFirst().forEach { path.addLine(to: $0) }
            botPts.reversed().forEach  { path.addLine(to: $0) }
            path.closeSubpath()
            let idx = gpu.colorIndex(for: name)
            ctx.fill(path, with: .color(
                Color(cgColor: ChartPalette.colors[idx % ChartPalette.colors.count]).opacity(0.85)
            ))
        }
    }

    // MARK: - Helpers

    private func paletteColor(for name: String) -> Color {
        Color(cgColor: ChartPalette.colors[gpu.colorIndex(for: name) % ChartPalette.colors.count])
    }

    private func currentPercent(for name: String) -> Double {
        gpu.history.last?.processes.first(where: { $0.name == name })?.gpuPercent ?? 0
    }

    private func intervalLabel(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private func loadColor(_ v: Double) -> Color {
        switch v {
        case ..<40:  return .green
        case ..<70:  return .yellow
        default:     return .red
        }
    }
}

// MARK: - Grid lines

struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for frac in [0.25, 0.5, 0.75] as [CGFloat] {
            let y = rect.height * (1 - frac)
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        for i in 1..<4 {
            let x = rect.width / 4 * CGFloat(i)
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return p
    }
}

#Preview {
    ContentView()
        .environmentObject(GPUDataSource())
        .frame(width: 760, height: 300)
}
