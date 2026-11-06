import SwiftUI

/// Battery monitor tab: live values, recording interval, display range, power source and Energy
/// Mode bars and three charts (charge %, system power, battery power) on a shared time axis.
struct BatteryView: View {
    @EnvironmentObject private var recorder: BatteryRecorder
    @AppStorage("batteryRange") private var range: BatteryRange = .h1

    var body: some View {
        Group {
            if recorder.hasBattery {
                BatteryCharts(recorder: recorder, range: $range)
            } else {
                Text("No battery detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 660, minHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Split out so it can own the BatteryHistory: StateObject can't read the environment in init.
private struct BatteryCharts: View {
    @ObservedObject var recorder: BatteryRecorder
    @Binding var range: BatteryRange
    @AppStorage("batteryChartStyle") private var style: ChartStyle = .averageBand
    @StateObject private var history: BatteryHistory

    init(recorder: BatteryRecorder, range: Binding<BatteryRange>) {
        self.recorder = recorder
        _range = range
        _history = StateObject(wrappedValue: BatteryHistory(recorder: recorder, range: range.wrappedValue))
    }

    private static let yAxisWidth: CGFloat = 44
    private static let chargeColor = Color(cgColor: ChartPalette.colors[0])      // blue
    private static let systemColor = Color(cgColor: ChartPalette.colors[2])      // orange
    private static let chargingColor = Color(cgColor: ChartPalette.colors[1])    // green
    private static let dischargingColor = Color(cgColor: ChartPalette.colors[4]) // red
    private static let acColor = Color(red: 0.12, green: 0.42, blue: 0.2)        // dark green
    private static let batteryColor = Color(white: 0.32)                        // dark grey

    static func color(_ mode: PowerMode) -> Color {
        switch mode {
        case .automatic: Color(nsColor: .systemGray)
        case .low:       Color(cgColor: ChartPalette.colors[6])  // yellow, as macOS shows Low Power
        case .high:      Color(cgColor: ChartPalette.colors[8])  // rose
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 6) {
                powerBar
                modeBar
                chargeChart
                systemChart
                batteryChart
            }
            .overlay {
                if history.buckets.runs.isEmpty && !history.isLoading {
                    Text("Collecting data…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onPreferenceChange(ChartWidthKey.self) { history.resize(columns: Int($0)) }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            timeAxis
        }
        .onChange(of: range) { history.range = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(BatteryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Time range shown")

            // An icon rather than the style's name: the header is full at the minimum width.
            Menu {
                Picker("Chart style", selection: $style) {
                    ForEach(ChartStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "chart.xyaxis.line")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chart style: \(style.help)")

            Spacer()

            // Legend for the mode bar; the current mode is emphasized. Shrinks when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(PowerMode.allCases, id: \.self) { modeLabel($0) }
                }
                if let mode = currentMode { modeLabel(mode) }
                if let mode = currentMode { modeDot(mode).help("Energy Mode: \(mode.label)") }
            }

            if let error = recorder.storeError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Recording failed: \(error)")
            }
            Picker("Interval", selection: $recorder.interval) {
                ForEach(BatteryRecorder.intervals, id: \.self) { Text("Every \(intervalLabel($0))").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Recording interval")

            // Drop the status text before anything else when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                    Text(statusText).font(.subheadline)
                }
                Image(systemName: statusSymbol).help(statusText)
            }
            .foregroundStyle(.secondary)
            Text(recorder.latest.map { String(format: "%.1f%%", $0.sample.chargePct) } ?? "–")
                .font(.title2.monospacedDigit().bold())
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var currentMode: PowerMode? { recorder.latest?.sample.powerMode }

    private func modeDot(_ mode: PowerMode) -> some View {
        Circle().fill(Self.color(mode)).frame(width: 8, height: 8)
    }

    private func modeLabel(_ mode: PowerMode) -> some View {
        HStack(spacing: 4) {
            modeDot(mode)
            Text(mode.label)
                .font(.caption)
                .fontWeight(mode == currentMode ? .semibold : .regular)
                .foregroundStyle(mode == currentMode ? .primary : .secondary)
                .fixedSize()
        }
    }

    private var statusText: String {
        guard let s = recorder.latest?.status else { return "" }
        if s.fullyCharged { return "Charged" }
        if s.isCharging { return "Charging" }
        if s.externalConnected { return "Plugged in" }
        return "On battery"
    }

    private var statusSymbol: String {
        guard let r = recorder.latest else { return "battery.0percent" }
        if r.status.externalConnected { return "battery.100percent.bolt" }
        let level = Int((r.sample.chargePct / 25).rounded()) * 25
        return "battery.\(level)percent"
    }

    // MARK: - Bars

    /// AC (dark green) or battery (dark grey), white labels.
    private var powerBar: some View {
        SpanBar(title: "Power", windowStart: history.windowStart, range: range.seconds, yAxisWidth: Self.yAxisWidth,
                textColor: .white,
                blocks: history.buckets.powerSpans.map {
                    SpanBar.Block(start: $0.start, end: $0.end, color: $0.ac ? Self.acColor : Self.batteryColor,
                                  name: $0.ac ? "AC power" : "Battery power", duration: $0.durationLabel)
                })
    }

    /// One color per Energy Mode, black labels: they read on all three colors in light and dark mode.
    private var modeBar: some View {
        SpanBar(title: "Mode", windowStart: history.windowStart, range: range.seconds, yAxisWidth: Self.yAxisWidth,
                textColor: .black,
                blocks: history.buckets.modeSpans.map {
                    SpanBar.Block(start: $0.start, end: $0.end, color: Self.color($0.mode),
                                  name: $0.mode.label, duration: $0.durationLabel)
                })
    }

    // MARK: - Charts

    private var chargeChart: some View {
        BatteryChart(
            title: "Charge",
            value: recorder.latest.map { String(format: "%.1f%%", $0.sample.chargePct) },
            lower: 0, upper: 100,
            yLabels: ["100%", "50%", "0%"],
            positiveColor: Self.chargeColor, negativeColor: Self.chargeColor,
            style: style,
            gridFractions: gridFractions,
            yAxisWidth: Self.yAxisWidth,
            columns: { history.columns(\.charge, width: $0) })
    }

    private var systemChart: some View {
        let top = Self.niceCeiling(Double(history.buckets.extent(\.system, style: style).max))
        return BatteryChart(
            title: "System",
            value: recorder.latest?.sample.systemPowerW.map { String(format: "%.1f W", $0) },
            lower: 0, upper: top,
            yLabels: [Self.watts(top), Self.watts(top / 2), "0 W"],
            positiveColor: Self.systemColor, negativeColor: Self.systemColor,
            style: style,
            gridFractions: gridFractions,
            yAxisWidth: Self.yAxisWidth,
            columns: { history.columns(\.system, width: $0) })
    }

    private var batteryChart: some View {
        let e = history.buckets.extent(\.battery, style: style)
        let top = Self.niceCeiling(max(abs(Double(e.min)), abs(Double(e.max))))
        return BatteryChart(
            title: "Battery",
            value: recorder.latest?.sample.batteryPowerW.map { Self.signedWatts($0) },
            lower: -top, upper: top,
            yLabels: ["+" + Self.watts(top), "0 W", "−" + Self.watts(top)],
            positiveColor: Self.chargingColor, negativeColor: Self.dischargingColor,
            style: style,
            gridFractions: gridFractions,
            yAxisWidth: Self.yAxisWidth,
            columns: { history.columns(\.battery, width: $0) })
    }

    // MARK: - Time axis

    /// Vertical grid lines, as fractions of the chart width: one per range.gridStep back from now.
    private var gridFractions: [CGFloat] {
        stride(from: range.gridStep, to: range.seconds, by: range.gridStep)
            .map { CGFloat(1 - $0 / range.seconds) }
    }

    private var timeAxis: some View {
        GeometryReader { geo in
            let steps = Int(range.seconds / range.gridStep)
            ForEach(0...steps, id: \.self) { k in
                let secondsAgo = Int(range.seconds) - k * Int(range.gridStep)
                // Zero-width frame: the first label starts at the left edge, the last ends at the
                // right edge, the rest are centered on their grid line.
                Text(range.axisLabel(secondsAgo: secondsAgo))
                    .fixedSize()
                    .frame(width: 0, alignment: k == 0 ? .leading : k == steps ? .trailing : .center)
                    .position(x: geo.size.width * CGFloat(k) / CGFloat(steps), y: geo.size.height / 2)
            }
        }
        .frame(height: 14)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.leading, 16 + Self.yAxisWidth + 4)
        .padding(.trailing, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Formatting

    private func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    /// Smallest round axis maximum ≥ v (…, 20, 25, 30, 40, 50, 60, 80, 100, …). Minimum 1.
    static func niceCeiling(_ v: Double) -> Double {
        guard v.isFinite, v > 1 else { return 1 }
        let magnitude = pow(10, (log10(v)).rounded(.down))
        for m in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where m * magnitude >= v * 0.999_999 { return m * magnitude }
        return 10 * magnitude
    }

    static func watts(_ v: Double) -> String {
        String(format: "%g W", v)
    }

    /// "+12.3 W" while charging, "−5.2 W" while discharging.
    static func signedWatts(_ v: Double) -> String {
        let sign = v >= 0.05 ? "+" : v <= -0.05 ? "−" : ""
        return sign + String(format: "%.1f W", v.magnitude)
    }
}

// MARK: - Span bar

/// Strip above the charts: one colored block per continuous stretch (on AC, in one Energy Mode, …),
/// labelled "<name>: <duration>" where it fits. Empty where nothing was recorded or the value is
/// unknown (history from before it was recorded).
private struct SpanBar: View {
    struct Block {
        let start: TimeInterval
        let end: TimeInterval
        let color: Color
        let name: String
        let duration: String
    }

    let title: String
    let windowStart: TimeInterval
    let range: TimeInterval
    let yAxisWidth: CGFloat
    let textColor: Color
    let blocks: [Block]

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: yAxisWidth, alignment: .trailing)
            Canvas { ctx, size in draw(ctx, size) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .frame(height: 20)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard range > 0 else { return }
        let scale = size.width / range
        for block in blocks {
            // At least a pixel wide, so a brief stretch stays visible at long ranges.
            let x0 = max(0, (block.start - windowStart) * scale)
            let x1 = min(size.width, max(x0 + 1, (block.end - windowStart) * scale))
            guard x1 > x0 else { continue }
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            ctx.fill(Path(rect), with: .color(block.color))

            // The full label if it fits, else just the duration, else nothing.
            for label in ["\(block.name): \(block.duration)", block.duration] {
                let text = ctx.resolve(Text(label).font(.caption2.monospacedDigit()).foregroundColor(textColor))
                if text.measure(in: size).width + 8 <= rect.width {
                    ctx.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                    break
                }
            }
        }
    }
}

// MARK: - Chart

/// Width of the chart canvases, which is also the number of pixel columns the history buckets.
private struct ChartWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One time series drawn from per-pixel columns in the given style: a line (with an area down to
/// zero when there's no band) and/or a shaded band. Values above zero use positiveColor, below
/// zero negativeColor. Recording gaps are bridged in grey and labelled "offline" with their duration.
private struct BatteryChart: View {
    private static let gapLineColor = Color(white: 0.55)  // grey
    private static let gapFillColor = Color(white: 0.32)  // dark grey
    private static let gapName = "offline"

    let title: String
    let value: String?
    let lower: Double
    let upper: Double
    /// Top, middle, bottom.
    let yLabels: [String]
    let positiveColor: Color
    let negativeColor: Color
    let style: ChartStyle
    let gridFractions: [CGFloat]
    let yAxisWidth: CGFloat
    let columns: (Int) -> [[BatteryBuckets.Column]]

    var body: some View {
        HStack(spacing: 4) {
            VStack(spacing: 0) {
                Text(yLabels[0])
                Spacer()
                Text(yLabels[1])
                Spacer()
                Text(yLabels[2])
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: yAxisWidth, alignment: .trailing)

            Canvas { ctx, size in draw(ctx, size) }
                .background(GeometryReader { Color.clear.preference(key: ChartWidthKey.self, value: $0.size.width) })
                .overlay(alignment: .topLeading) { titleLabel }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .frame(minHeight: 50)
    }

    private var titleLabel: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            if let value { Text(value).monospacedDigit() }
        }
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.75),
                    in: RoundedRectangle(cornerRadius: 4))
        .padding(4)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let span = upper - lower
        guard span > 0, size.width > 0, size.height > 0 else { return }
        func y(_ v: Float) -> CGFloat { size.height * CGFloat(1 - (Double(v) - lower) / span) }
        let zero = y(Float(min(max(0, lower), upper)))

        // Grid: horizontal quarters, vertical time steps, and the zero line when it's inside.
        var grid = Path()
        for frac in [0.25, 0.5, 0.75] as [CGFloat] {
            grid.move(to: CGPoint(x: 0, y: size.height * frac))
            grid.addLine(to: CGPoint(x: size.width, y: size.height * frac))
        }
        for frac in gridFractions {
            grid.move(to: CGPoint(x: size.width * frac, y: 0))
            grid.addLine(to: CGPoint(x: size.width * frac, y: size.height))
        }
        ctx.stroke(grid, with: .color(Color(nsColor: .separatorColor).opacity(0.7)), lineWidth: 0.5)
        if lower < 0 && upper > 0 {
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: zero))
            axis.addLine(to: CGPoint(x: size.width, y: zero))
            ctx.stroke(axis, with: .color(.secondary.opacity(0.6)), lineWidth: 0.75)
        }

        // Data, per run: the bands, the line, and below a bandless line an area down to zero.
        // A run of one column becomes short bars or a dot.
        let opacities = bandOpacities
        var bands = opacities.map { _ in Path() }
        var area = Path(), line = Path(), dots = Path()
        let runs = columns(Int(size.width))
        for run in runs {
            let xs = run.map { CGFloat($0.x) }
            let edges = run.map { style.bands($0.summary) }
            for j in bands.indices {
                // Half a point extra each way keeps a flat band visible.
                let top = edges.map { y($0[j].high) - 0.5 }, bottom = edges.map { y($0[j].low) + 0.5 }
                if run.count == 1 {
                    bands[j].addRect(CGRect(x: xs[0] - 1, y: top[0], width: 2, height: bottom[0] - top[0]))
                } else {
                    bands[j].move(to: CGPoint(x: xs[0], y: top[0]))
                    for i in run.indices.dropFirst() { bands[j].addLine(to: CGPoint(x: xs[i], y: top[i])) }
                    for i in run.indices.reversed() { bands[j].addLine(to: CGPoint(x: xs[i], y: bottom[i])) }
                    bands[j].closeSubpath()
                }
            }
            let values = run.compactMap { style.line($0.summary) }
            if values.count == run.count {
                let ys = values.map { y($0) }
                if run.count == 1 {
                    dots.addRect(CGRect(x: xs[0] - 1, y: ys[0] - 1, width: 2, height: 2))
                } else {
                    line.move(to: CGPoint(x: xs[0], y: ys[0]))
                    for i in run.indices.dropFirst() { line.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
                    if bands.isEmpty {
                        area.move(to: CGPoint(x: xs[0], y: zero))
                        for i in run.indices { area.addLine(to: CGPoint(x: xs[i], y: ys[i])) }
                        area.addLine(to: CGPoint(x: xs[xs.count - 1], y: zero))
                        area.closeSubpath()
                    }
                }
            }
        }

        // A line sitting exactly on zero would be split between both colors; leave it to the axis.
        let gap: CGFloat = 0.6
        for (rect, color) in [(CGRect(x: 0, y: 0, width: size.width, height: zero - gap), positiveColor),
                              (CGRect(x: 0, y: zero + gap, width: size.width, height: size.height - zero - gap), negativeColor)] {
            var layer = ctx
            layer.clip(to: Path(rect))
            layer.fill(area, with: .color(color.opacity(0.25)))
            for (band, opacity) in zip(bands, opacities) { layer.fill(band, with: .color(color.opacity(opacity))) }
            layer.stroke(line, with: .color(color), lineWidth: 1)
            layer.fill(dots, with: .color(color))
        }

        for (before, after) in zip(runs, runs.dropFirst()) {
            drawGap(ctx, size, from: before[before.count - 1], to: after[0], zero: zero, y: y)
        }
    }

    /// A recording gap (asleep, app not running) between two runs: the edge columns joined by
    /// straight lines in grey, the filled part (outermost band, or the area down to zero when
    /// there's no band) in dark grey with a white label in its middle. Where that part is too
    /// thin for the label, the label goes above or below it in the secondary color instead.
    /// Like the span bars, the label is "offline: <duration>" if it fits, else just the duration.
    private func drawGap(_ ctx: GraphicsContext, _ size: CGSize, from a: BatteryBuckets.Column,
                         to b: BatteryBuckets.Column, zero: CGFloat, y: (Float) -> CGFloat) {
        let x0 = CGFloat(a.x), x1 = CGFloat(b.x)
        guard x1 > x0 else { return }

        // The filled part's two edges as y at x0 and x1, like the data: bands half a point wider.
        let lineA = style.line(a.summary).map(y), lineB = style.line(b.summary).map(y)
        let edges: (top: (CGFloat, CGFloat), bottom: (CGFloat, CGFloat))
        if let bandA = style.bands(a.summary).first, let bandB = style.bands(b.summary).first {
            edges = ((y(bandA.high) - 0.5, y(bandB.high) - 0.5), (y(bandA.low) + 0.5, y(bandB.low) + 0.5))
        } else if let lineA, let lineB {
            edges = ((lineA, lineB), (zero, zero))
        } else {
            return
        }
        var fill = Path()
        fill.move(to: CGPoint(x: x0, y: edges.top.0))
        fill.addLine(to: CGPoint(x: x1, y: edges.top.1))
        fill.addLine(to: CGPoint(x: x1, y: edges.bottom.1))
        fill.addLine(to: CGPoint(x: x0, y: edges.bottom.0))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(Self.gapFillColor))
        if let lineA, let lineB {
            var line = Path()
            line.move(to: CGPoint(x: x0, y: lineA))
            line.addLine(to: CGPoint(x: x1, y: lineB))
            ctx.stroke(line, with: .color(Self.gapLineColor), lineWidth: 1)
        }

        // Label: centered on the gap, the first one that fits.
        let font = Font.caption2.monospacedDigit()
        let duration = BatteryBuckets.durationLabel(b.first - a.last)
        let mid = (x0 + x1) / 2
        func at(_ e: (CGFloat, CGFloat), _ x: CGFloat) -> CGFloat { e.0 + (e.1 - e.0) * (x - x0) / (x1 - x0) }
        for label in ["\(Self.gapName): \(duration)", duration] {
            let textSize = ctx.resolve(Text(label).font(font)).measure(in: size)
            let half = textSize.width / 2 + 3
            guard x1 - x0 >= 2 * half + 4 else { continue }
            // Both edges are straight, so the filled part fits the label's box iff it covers the box
            // at the box's left and right ends: the span between the edges at both ends, intersected.
            let ends = [mid - half, mid + half].map { x in
                (min(at(edges.top, x), at(edges.bottom, x)), max(at(edges.top, x), at(edges.bottom, x)))
            }
            let inside = (ends.map(\.0).max()!, ends.map(\.1).min()!)
            let outside = (ends.map(\.0).min()!, ends.map(\.1).max()!)
            let height = textSize.height + 2
            if inside.1 - inside.0 >= height {
                let center = CGPoint(x: mid, y: (inside.0 + inside.1) / 2)
                // A dark grey backdrop keeps a line through the band from crossing the text.
                ctx.fill(Path(CGRect(x: center.x - half, y: center.y - height / 2, width: 2 * half, height: height)),
                         with: .color(Self.gapFillColor))
                ctx.draw(ctx.resolve(Text(label).font(font).foregroundColor(.white)), at: center)
                return
            } else if outside.0 >= height || size.height - outside.1 >= height {
                let y = outside.0 >= height ? outside.0 - height / 2 : outside.1 + height / 2
                ctx.draw(ctx.resolve(Text(label).font(font).foregroundColor(.secondary)), at: CGPoint(x: mid, y: y))
                return
            }
        }
    }

    /// Fill opacity of each of style.bands, outermost first. A band standing alone gets more
    /// weight than one behind a line; nested bands get darker inwards.
    private var bandOpacities: [Double] {
        switch style {
        case .average:     []
        case .minMax:      [0.6]
        case .averageBand: [0.3]
        case .quartiles:   [0.2, 0.45]
        }
    }
}
