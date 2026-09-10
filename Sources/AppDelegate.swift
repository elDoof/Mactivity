import SwiftUI
import AppKit

/// Default values for every `@AppStorage` key in ContentView. Registering them
/// keeps `UserDefaults.standard.bool(forKey:)` in AppDelegate in agreement with
/// the SwiftUI defaults — without this, the menu bar label reads `false` for
/// every toggle until the user flips one.
enum Defaults {
    static let registry: [String: Any] = [
        "showTopProcesses": true,
        "appTheme": AppTheme.blue.rawValue,
        "isFloatingWidget": false,
        "isCompactMode": false,
        "menuBarShowCPU": true,
        "menuBarShowRAM": false,
        "menuBarShowNetwork": false,
        "menuBarShowBattery": false,
    ]
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var monitor = ActivityMonitor()
    private var labelTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Defaults.registry)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        popover.delegate = self
        // The content view controller is created on demand in togglePopover and
        // discarded in popoverDidClose -- see that method for why.

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Set initial icon
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Mactivity Monitor")
            button.imagePosition = .imageLeading
            // Without an explicit target the action falls back to the responder
            // chain, which is fragile for a status item.
            button.target = self
            button.action = #selector(togglePopover)
        }
        updateButton()

        // Update menu bar label every second, in .common so it keeps ticking
        // while a menu or the popover is tracking.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateButton()
        }
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer

        // Restore the floating widget if it was left enabled.
        if UserDefaults.standard.bool(forKey: "isFloatingWidget") {
            FloatingWindowManager.shared.toggle(monitor: monitor, isFloating: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        labelTimer?.invalidate()
        monitor.stopMonitoring()
    }

    /// Finder/Dock reopen: with no windows and no Settings scene there is
    /// nothing for macOS to show, so show the popover explicitly.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return true
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if popover.contentViewController == nil {
                let root = ContentView(monitor: monitor, onHeightChange: { [weak self] height in
                    self?.resizePopover(toContentHeight: height)
                })
                popover.contentViewController = NSHostingController(rootView: root)
            }
            sizePopover(on: button.window?.screen)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // A transient popover needs the app active to reliably take key,
            // otherwise controls inside it swallow the first click.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// NSPopover retains its content view controller, so a SwiftUI hierarchy
    /// left in place keeps re-rendering its four Charts every second even
    /// while hidden -- roughly 23% CPU indefinitely after the first open.
    /// Dropping it on close returns the app to idle; rebuilding on the next
    /// open is cheap.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    /// The popover is anchored under the menu bar, so anything taller than the
    /// screen is clipped rather than scrolled. Size it to the content's
    /// natural height, capped to what the screen can actually show. This is
    /// the size it opens at; `resizePopover` then follows the content.
    private func sizePopover(on screen: NSScreen?) {
        let natural = ContentView.naturalHeight(monitor: monitor)
        popover.contentSize = NSSize(width: 340, height: cappedHeight(natural, on: screen))
    }

    /// Follows content that changes height while the popover is open — opening
    /// the settings pane, or toggling compact mode — which would otherwise
    /// leave the popover at whatever size it opened at until it was reopened.
    private func resizePopover(toContentHeight height: CGFloat) {
        guard popover.contentViewController != nil else { return }
        let target = cappedHeight(height, on: statusItem.button?.window?.screen)
        guard abs(popover.contentSize.height - target) > 1 else { return }
        popover.contentSize = NSSize(width: 340, height: target)
    }

    private func cappedHeight(_ height: CGFloat, on screen: NSScreen?) -> CGFloat {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(height, available - 24)
    }

    func updateButton() {
        guard let button = statusItem.button else { return }

        let defaults = UserDefaults.standard
        let showCPU = defaults.bool(forKey: "menuBarShowCPU")
        let showRAM = defaults.bool(forKey: "menuBarShowRAM")
        let showNetwork = defaults.bool(forKey: "menuBarShowNetwork")
        let showBattery = defaults.bool(forKey: "menuBarShowBattery")

        var parts: [String] = []
        if showCPU { parts.append(String(format: "C:%.0f%%", monitor.cpuUsage)) }
        if showRAM { parts.append(String(format: "R:%.0f%%", monitor.memoryUsage)) }
        if showNetwork { parts.append("\u{2193}" + monitor.networkDownloadRate.replacingOccurrences(of: "/s", with: "")) }
        if showBattery && monitor.hasBattery {
            parts.append(String(format: "B:%.0f%%", monitor.batteryPercent))
        }

        let text = parts.joined(separator: " ")
        // Keep the font monospaced so the label stops jittering as digits change.
        button.attributedTitle = NSAttributedString(
            string: text.isEmpty ? "" : " " + text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]
        )
    }
}
