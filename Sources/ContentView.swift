import SwiftUI
import ServiceManagement

enum AppTheme: String, CaseIterable, Identifiable {
    case blue = "Blue", mint = "Mint", purple = "Purple", orange = "Orange", pink = "Pink", green = "Green"
    var id: String { self.rawValue }
    var color: Color {
        switch self {
        case .blue: return .blue
        case .mint: return .mint
        case .purple: return .purple
        case .orange: return .orange
        case .pink: return .pink
        case .green: return .green
        }
    }
}

/// Measured height of the header, which sits outside the scroll view.
private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Measured height of the scrollable content. Together with the header this
/// gives the height the popover or panel needs, so it can follow content that
/// grows or shrinks (compact mode, the settings pane) instead of only being
/// sized when it opens.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

final class FloatingWindowManager: NSObject, NSWindowDelegate {
    static let shared = FloatingWindowManager()
    private(set) var window: NSWindow?

    func toggle(monitor: ActivityMonitor, isFloating: Bool) {
        if isFloating {
            if window == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 700),
                                    styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .hudWindow],
                                    backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.backgroundColor = .clear
                panel.isMovableByWindowBackground = true
                panel.hidesOnDeactivate = false
                // Without this the panel is destroyed on close and the stored
                // reference dangles.
                panel.isReleasedWhenClosed = false
                panel.delegate = self

                // A borderless panel collapses to zero if it is sized from a
                // hosting controller's intrinsic size, so drive the size from
                // the hosting view's fittingSize and cap it to the screen.
                let view = NSHostingView(rootView: StandaloneContentView(monitor: monitor))
                panel.contentView = view
                let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 40
                let natural = ContentView.naturalHeight(monitor: monitor)
                panel.setContentSize(NSSize(width: 340, height: min(natural, maxHeight)))
                panel.center()
                self.window = panel
            }
            window?.orderFrontRegardless()
        } else {
            // orderOut alone leaves the panel and its hosting view alive.
            window?.delegate = nil
            window?.close()
            window?.contentView = nil
            window = nil
        }
    }

    /// Follows the content height, keeping the panel's top edge where the user
    /// put it rather than growing downward from the bottom-left origin.
    func resize(toContentHeight height: CGFloat) {
        guard let window, height > 100 else { return }
        let maxHeight = ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 40
        let target = min(height, maxHeight)
        var frame = window.frame
        let sized = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 340, height: target))
        guard abs(frame.height - sized.height) > 1 else { return }
        frame.origin.y += frame.height - sized.height
        frame.size = sized.size
        window.setFrame(frame, display: true)
    }

    /// Called if the panel is ever closed by something other than `toggle`,
    /// so the persisted preference does not drift out of sync.
    func windowWillClose(_ notification: Notification) {
        window = nil
        UserDefaults.standard.set(false, forKey: "isFloatingWidget")
    }
}

struct StandaloneContentView: View {
    @ObservedObject var monitor: ActivityMonitor
    var body: some View {
        ContentView(monitor: monitor, isStandalone: true, onHeightChange: { height in
            FloatingWindowManager.shared.resize(toContentHeight: height)
        })
        .background(VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 16)))
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct RingView: View {
    var value: Double
    var color: Color
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(lineWidth: 7).opacity(0.15).foregroundColor(color)
                Circle()
                    .trim(from: 0.0, to: CGFloat(min(max(value / 100.0, 0), 1)))
                    .stroke(style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .foregroundColor(color)
                    .rotationEffect(Angle(degrees: 270.0))
                    // Values arrive once a second, so the animation has to
                    // settle well inside that second. A spring took about as
                    // long as the interval itself, leaving the ring animating
                    // -- and re-rasterising its shadow -- without pause.
                    .animation(.easeOut(duration: 0.25), value: value)

                Text(String(format: "%.0f%%", value.isFinite ? value : 0))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 50, height: 50)

            VStack(spacing: 1) {
                Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(.primary)
                Text(subtitle).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: "%.0f percent. %@", value, subtitle))
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(color).frame(width: 20)
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}

struct MiniGraphView: View {
    let title: String
    let icon: String
    let color: Color
    let history: [DataPoint]
    let dynamicScale: Bool

    init(title: String, icon: String, color: Color, history: [DataPoint], dynamicScale: Bool = false) {
        self.title = title
        self.icon = icon
        self.color = color
        self.history = history
        self.dynamicScale = dynamicScale
    }

    /// Index into `history` under the pointer. Holding an index rather than a
    /// sample means the readout follows the cursor position as the window
    /// scrolls, instead of freezing on a sample that has aged out.
    @State private var hoveredIndex: Int?

    /// Percentage graphs are pinned to 0-100 so the shape is comparable over
    /// time; the network graph has no ceiling, so it tracks its own peak.
    private var upperBound: Double {
        guard dynamicScale else { return 100 }
        let peak = history.map(\.value).max() ?? 0
        return peak > 1 ? peak * 1.15 : 1
    }

    private var hoveredValue: Double? {
        guard let index = hoveredIndex, history.indices.contains(index) else { return nil }
        return history[index].value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: icon)
                Text(title).font(.system(size: 10, weight: .semibold))
                Spacer()
                if let value = hoveredValue {
                    Text(String(format: dynamicScale ? "%.1f" : "%.0f%%", value))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
            }
            .foregroundColor(color)

            graph.frame(height: 40)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(format: dynamicScale ? "%.1f" : "%.0f percent",
                                   history.last?.value ?? 0))
    }

    /// Drawn straight into a Canvas rather than with SwiftUI Charts. Four of
    /// these refresh every second, and Charts builds a view per data point --
    /// together they cost about a third of a core with the panel open. Canvas
    /// rasterises one layer imperatively for a small fraction of that.
    private var graph: some View {
        GeometryReader { proxy in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                guard history.count > 1, size.width > 0, size.height > 0 else { return }

                let bound = upperBound
                let stepX = size.width / CGFloat(history.count - 1)

                func position(_ index: Int) -> CGPoint {
                    let fraction = min(max(history[index].value / bound, 0), 1)
                    return CGPoint(x: CGFloat(index) * stepX,
                                   y: size.height - CGFloat(fraction) * size.height)
                }

                var line = Path()
                line.move(to: position(0))
                for index in 1..<history.count { line.addLine(to: position(index)) }

                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()

                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.3), color.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                if let index = hoveredIndex, history.indices.contains(index) {
                    let point = position(index)
                    var rule = Path()
                    rule.move(to: CGPoint(x: point.x, y: 0))
                    rule.addLine(to: CGPoint(x: point.x, y: size.height))
                    context.stroke(rule, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5,
                                                        width: 5, height: 5)),
                                 with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let width = proxy.size.width
                    guard width > 0, history.count > 1 else { hoveredIndex = nil; return }
                    let raw = (location.x / width) * CGFloat(history.count - 1)
                    hoveredIndex = min(max(Int(raw.rounded()), 0), history.count - 1)
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
    }
}

struct CoreEqualizerView: View {
    var coreUsages: [Double]
    var accentColor: Color

    /// Drawn as a single Canvas. Previously each core was its own animated
    /// view, so SwiftUI re-ran layout for every bar on every display frame --
    /// with the panel visible that alone accounted for most of the app's CPU.
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            guard !coreUsages.isEmpty, size.height > 0 else { return }

            let barWidth: CGFloat = 4
            let spacing: CGFloat = 2
            for (index, usage) in coreUsages.enumerated() {
                let x = CGFloat(index) * (barWidth + spacing)
                guard x + barWidth <= size.width else { break }

                let clamped = min(max(usage, 0), 100)
                let height = max(CGFloat(clamped / 100.0) * size.height, 2)
                let bar = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                let color: Color = clamped > 80 ? .red : (clamped > 50 ? .yellow : accentColor)
                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(color))
            }
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-core CPU usage")
        .accessibilityValue("\(coreUsages.count) cores")
    }
}

struct ContentView: View {
    @ObservedObject var monitor: ActivityMonitor
    var isStandalone: Bool = false
    /// When false the content is laid out without a scroll view, so its
    /// natural height can be measured. See `AppDelegate.sizePopover`.
    var scrolls: Bool = true
    /// Reports the height the container needs whenever the content changes
    /// size, so the popover and the floating panel can follow it.
    var onHeightChange: ((CGFloat) -> Void)? = nil

    @AppStorage("showTopProcesses") private var showTopProcesses = true
    @AppStorage("appTheme") private var appTheme: AppTheme = .blue
    @AppStorage("isFloatingWidget") private var isFloatingWidget = false
    @AppStorage("isCompactMode") private var isCompactMode = false

    @AppStorage("menuBarShowCPU") private var menuBarShowCPU = true
    @AppStorage("menuBarShowRAM") private var menuBarShowRAM = false
    @AppStorage("menuBarShowNetwork") private var menuBarShowNetwork = false
    @AppStorage("menuBarShowBattery") private var menuBarShowBattery = false
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true

    @ObservedObject private var updater = Updater.shared

    @State private var showingSettings = false
    @State private var headerHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    @ViewBuilder
    private var panelContent: some View {
        if showingSettings {
            settingsView
        } else {
            mainView
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header.background(measure(HeaderHeightKey.self))
            // The height comes from AppKit (the popover's contentSize, or the
            // panel's frame): SwiftUI's intrinsic size for a ScrollView is not
            // dependable, and asking for it produced a collapsed popover.
            // Measuring the two pieces separately matters — measuring the
            // whole stack would just report back the height AppKit imposed.
            if scrolls {
                ScrollView { panelContent.background(measure(ContentHeightKey.self)) }
            } else {
                panelContent.background(measure(ContentHeightKey.self))
            }
        }
        .frame(width: 340)
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .onChange(of: headerHeight + contentHeight) { _, total in
            if total > 100 { onHeightChange?(total) }
        }
        .onAppear {
            monitor.startMonitoring()
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: isFloatingWidget) {
            if !isStandalone {
                FloatingWindowManager.shared.toggle(monitor: monitor, isFloating: isFloatingWidget)
            }
        }
    }

    private func measure<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline)
                .foregroundStyle(appTheme.color.gradient)
            Text("Mactivity")
                .font(.system(.headline, design: .rounded))
                .fontWeight(.bold)
            Spacer()

            if isStandalone {
                // The floating panel is borderless, so it needs its own dismiss.
                Button {
                    isFloatingWidget = false
                    FloatingWindowManager.shared.toggle(monitor: monitor, isFloating: false)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close widget")
            } else {
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: showingSettings ? "chevron.left.circle.fill" : "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(showingSettings ? "Back" : "Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
    }

    /// Lays the content out without a scroll view to learn its natural height.
    /// A ScrollView reports no dependable ideal height, so the size that the
    /// popover and the floating panel need has to be measured this way.
    static func naturalHeight(monitor: ActivityMonitor) -> CGFloat {
        let probe = NSHostingView(rootView: ContentView(monitor: monitor, scrolls: false))
        probe.layoutSubtreeIfNeeded()
        let height = probe.fittingSize.height
        return height > 100 ? height : 700
    }

    // MARK: - Settings

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsSection("MENU BAR") {
                Toggle("CPU", isOn: $menuBarShowCPU)
                Toggle("Memory", isOn: $menuBarShowRAM)
                Toggle("Network", isOn: $menuBarShowNetwork)
                Toggle("Battery", isOn: $menuBarShowBattery)
                    .disabled(!monitor.hasBattery)
            }

            settingsSection("PANEL") {
                Toggle("Compact mode", isOn: $isCompactMode)
                Toggle("Show top processes", isOn: $showTopProcesses)
                Toggle("Floating widget", isOn: $isFloatingWidget)
                HStack {
                    Text("Accent").font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }

            settingsSection("GENERAL") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                ))
                if let error = launchAtLoginError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("UPDATES") {
                HStack {
                    Text("Version \(updater.currentVersion)").font(.system(size: 12))
                    Spacer()
                }
                Toggle("Check automatically", isOn: $automaticUpdateChecks)
                updateControls
            }

            // An LSUIElement app has no menu bar of its own, so without this
            // there is no way to quit short of force-killing it.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit Mactivity")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.18))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")

            Spacer(minLength: 8)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    /// The update pane never installs anything on its own: each step past
    /// "an update exists" is a separate, explicit click.
    @ViewBuilder
    private var updateControls: some View {
        if !updater.canUpdate {
            Text("Updates are only available in an installed copy of Mactivity.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch updater.status {
            case .idle:
                updateButton("Check for Updates") { updater.checkNow() }
            case .checking:
                updateNote("Checking...")
            case .upToDate:
                updateNote("Mactivity is up to date.")
                updateButton("Check Again") { updater.checkNow() }
            case .available(let version):
                updateNote("Version \(version) is available.")
                updateButton("Download \(version)") { updater.downloadUpdate() }
            case .downloading:
                updateNote("Downloading...")
            case .verifying:
                updateNote("Verifying signature...")
            case .readyToInstall(let version):
                updateNote("Version \(version) is ready to install.")
                updateButton("Install and Relaunch") { updater.installAndRelaunch() }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                updateButton("Try Again") { updater.checkNow() }
            }
        }
    }

    private func updateNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updateButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(appTheme.color.opacity(0.2))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .disabled(updater.isBusy)
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            content()
                .font(.system(size: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Registration needs a signed bundle in /Applications; surface the
            // failure instead of silently leaving the switch in a false state.
            launchAtLoginError = "Could not update: \(error.localizedDescription)"
        }
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Main

    private var mainView: some View {
        VStack(spacing: 12) {
            // Hardware Info Panel
            VStack(spacing: 4) {
                Text(monitor.macModel.isEmpty ? "Loading Hardware..." : monitor.macModel)
                    .font(.system(size: 11, weight: .bold))
                HStack {
                    Text(monitor.gpuName).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                    Spacer()
                    Text("IP: \(monitor.localIP)").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))

            // Rings Row
            HStack(spacing: 12) {
                RingView(value: monitor.cpuUsage, color: appTheme.color, title: "CPU", subtitle: "Load")
                RingView(value: monitor.gpuUsage, color: .mint, title: "GPU", subtitle: "Load")
                RingView(value: monitor.memoryUsage, color: .purple, title: "MEM", subtitle: monitor.usedMemoryCompact)
                RingView(value: monitor.diskUsagePercent, color: .orange, title: "DISK", subtitle: monitor.usedDiskCompact)
            }
            .padding(.vertical, 12).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))

            // Detailed Memory Panel
            if !isCompactMode {
                VStack(spacing: 8) {
                    HStack {
                        Text("MEMORY PRESSURE").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                        Spacer()
                        Text(monitor.memoryPressure)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(monitor.memoryPressureColor)
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(monitor.appMemoryString).font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("Wired").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(monitor.wiredMemoryString).font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Compressed").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(monitor.compressedMemoryString).font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }

            // Per-Core Equalizer
            VStack(alignment: .leading, spacing: 6) {
                Text("CORES").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                if !monitor.coreUsages.isEmpty {
                    CoreEqualizerView(coreUsages: monitor.coreUsages, accentColor: appTheme.color)
                } else {
                    Text("Loading...").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))

            // Top Processes
            if showTopProcesses && !monitor.topProcesses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TOP PROCESSES (CPU)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)

                    ForEach(monitor.topProcesses) { process in
                        HStack {
                            Text(process.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpu))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(process.cpu > 50.0 ? .red : .primary)

                            Button {
                                // A plain click asks the process to quit; only
                                // Option-click forces it, so a mis-click cannot
                                // throw away someone's unsaved work.
                                monitor.terminateProcess(pid: process.pid,
                                                         force: NSEvent.modifierFlags.contains(.option))
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Quit \(process.name) (pid \(process.pid)) — hold Option to force quit")
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))
            }

            // Network & Uptime (Hidden in compact mode)
            if !isCompactMode {
                VStack(spacing: 8) {
                    InfoRow(icon: "arrow.down.circle.fill", title: "Download", value: monitor.networkDownloadRate, color: .cyan)
                    InfoRow(icon: "arrow.up.circle.fill", title: "Upload", value: monitor.networkUploadRate, color: .pink)
                    Divider()
                    InfoRow(icon: "internaldrive.fill", title: "Disk Read", value: monitor.diskReadRate, color: .orange)
                    InfoRow(icon: "internaldrive.fill", title: "Disk Write", value: monitor.diskWriteRate, color: .orange)
                    Divider()
                    InfoRow(icon: "clock.fill", title: "Uptime", value: monitor.upTime, color: .yellow)
                    if monitor.hasBattery {
                        InfoRow(icon: monitor.batteryIsCharging ? "battery.100.bolt" : "battery.50",
                                title: "Battery",
                                value: String(format: "%.0f%%%@", monitor.batteryPercent, monitor.batteryIsCharging ? " charging" : ""),
                                color: monitor.batteryPercent < 20 ? .red : .green)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(NSColor.controlBackgroundColor).opacity(0.6)))

                // Graphs
                VStack(spacing: 8) {
                    MiniGraphView(title: "CPU History", icon: "cpu", color: appTheme.color, history: monitor.cpuHistory)
                    MiniGraphView(title: "GPU History", icon: "sparkles.tv", color: .mint, history: monitor.gpuHistory)
                    MiniGraphView(title: "Memory History", icon: "memorychip", color: .purple, history: monitor.memoryHistory)
                    MiniGraphView(title: "Network History (KB/s)", icon: "network", color: .cyan, history: monitor.networkHistory, dynamicScale: true)
                }
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}
