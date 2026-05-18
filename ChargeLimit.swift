import SwiftUI
import AppKit
import Combine
import IOKit
import IOKit.ps

// MARK: - batt CLI wrapper

final class BattClient {
    static let shared = BattClient()

    var executablePath: String? {
        let candidates = ["/opt/homebrew/bin/batt", "/usr/local/bin/batt", "/usr/bin/batt"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isInstalled: Bool { executablePath != nil }

    var isDaemonRunning: Bool {
        guard isInstalled else { return false }
        let result = run(["status"])
        let lower = result.output.lowercased()
        return !lower.contains("daemon is not running") && !lower.contains("daemon not running")
    }

    @discardableResult
    func run(_ args: [String]) -> (output: String, exitCode: Int32) {
        guard let path = executablePath else { return ("", -1) }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
        } catch {
            return ("\(error)", -1)
        }
    }

    // Reads `batt status` and extracts the current limit (10-100).
    // Note: batt reports limit=100 as "disabled" — but that's just a value, not a separate state.
    // We treat it purely as a number; UI snooze state is tracked in the model.
    func readLimit() -> Int? {
        let result = run(["status"])
        for raw in result.output.split(separator: "\n") {
            let line = String(raw)
            // Look for the "Charge limit:" line specifically
            if line.lowercased().contains("charge limit:") {
                let scanner = Scanner(string: line)
                scanner.charactersToBeSkipped = CharacterSet.decimalDigits.inverted
                if let n = scanner.scanInt(), n >= 10, n <= 100 {
                    return n
                }
            }
        }
        return nil
    }

    func setLimit(_ value: Int) {
        // Run off the main thread — the Process call can take a few hundred ms
        // and we don't want to block UI responsiveness during slider commits.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.run(["limit", "\(value)"])
        }
    }

    func disable() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.run(["disable"])
        }
    }
}

// MARK: - Battery info (IOKit)

struct BatteryInfo {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let isLowPowerMode: Bool

    var statusLabel: String {
        if !isPluggedIn { return "On battery" }
        if isCharging { return "Charging" }
        return "Plugged in, not charging"
    }

    var symbolName: String {
        if isCharging { return "bolt.fill" }
        if isPluggedIn { return "powerplug.fill" }
        switch percent {
        case 0..<10:  return "battery.0"
        case 10..<35: return "battery.25"
        case 35..<60: return "battery.50"
        case 60..<85: return "battery.75"
        default:      return "battery.100"
        }
    }

    static func current() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            let percent = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
            let powerState = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let isPluggedIn = (powerState == (kIOPSACPowerValue as String))
            return BatteryInfo(percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn, isLowPowerMode: lpm)
        }
        return nil
    }
}

// MARK: - Menu bar icon renderer

enum MenuBarIcon {
    private static let symbolPointSize: CGFloat = 20

    static func image(for info: BatteryInfo) -> NSImage? {
        // Always render fill from real percentage via the variable-value symbol.
        let value = max(0.0, min(1.0, Double(info.percent) / 100.0))
        var battery = NSImage(systemSymbolName: "battery.0to100",
                              variableValue: value,
                              accessibilityDescription: "Battery: \(info.percent)%")
        if battery == nil {
            // Discrete fallback if 0to100 unavailable on this system
            let step: Int
            switch info.percent {
            case 0..<13:   step = 0
            case 13..<38:  step = 25
            case 38..<63:  step = 50
            case 63..<88:  step = 75
            default:       step = 100
            }
            battery = NSImage(systemSymbolName: "battery.\(step)",
                              accessibilityDescription: "Battery: \(info.percent)%")
        }
        if battery == nil {
            battery = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery")
        }

        // Color rules: red ≤20%, else yellow on LPM, else template (auto-tints)
        let useTemplate: Bool
        let tint: NSColor?
        if info.percent <= 20 {
            tint = .systemRed; useTemplate = false
        } else if info.isLowPowerMode {
            tint = .systemYellow; useTemplate = false
        } else {
            tint = nil; useTemplate = true
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let finalConfig: NSImage.SymbolConfiguration
        if let tint = tint {
            finalConfig = sizeConfig.applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        } else {
            finalConfig = sizeConfig
        }
        battery = battery?.withSymbolConfiguration(finalConfig)

        // When plugged in (charging OR at limit), punch a bolt-shaped cutout
        // through the fill — same visual as Apple's menu bar battery.
        var result = battery
        if info.isPluggedIn, let base = battery {
            result = boltCutout(over: base)
        }
        result?.isTemplate = useTemplate
        return result
    }

    private static func boltCutout(over battery: NSImage) -> NSImage {
        // Smaller, lighter bolt so it sits cleanly inside the battery body — matches Apple's icon
        let boltConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize * 0.45, weight: .medium)
        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(boltConfig) else {
            return battery
        }

        let size = battery.size
        let out = NSImage(size: size)
        out.lockFocus()

        battery.draw(at: .zero,
                     from: NSRect(origin: .zero, size: size),
                     operation: .sourceOver,
                     fraction: 1.0)

        // Center the bolt in the battery body — slight left shift accounts for the cap on the right
        let boltSize = bolt.size
        let x = (size.width - boltSize.width) / 2 - size.width * 0.04
        let y = (size.height - boltSize.height) / 2
        bolt.draw(at: NSPoint(x: x, y: y),
                  from: NSRect(origin: .zero, size: boltSize),
                  operation: .destinationOut,
                  fraction: 1.0)

        out.unlockFocus()
        return out
    }
}

// MARK: - Model

final class AppModel: ObservableObject {
    @Published var currentLimit: Int = 80
    @Published var snoozedUntil: Date? = nil
    @Published var battInstalled: Bool = false
    @Published var daemonRunning: Bool = false
    @Published var battery: BatteryInfo? = nil
    @Published var lastError: String? = nil

    var isSnoozed: Bool { snoozedUntil != nil }

    private var midnightTimer: Timer?
    private var refreshTimer: Timer?
    private var aggressiveTimer: Timer?
    private var savedLimitForSnooze: Int = 80
    private let savedLimitKey = "ChargeLimit.savedLimit"

    init() {
        let saved = UserDefaults.standard.integer(forKey: savedLimitKey)
        if [80, 85, 90, 95, 100].contains(saved) {
            currentLimit = saved
        }
        refresh()
    }

    func refresh() {
        battInstalled = BattClient.shared.isInstalled
        battery = BatteryInfo.current()
        guard battInstalled else { daemonRunning = false; return }
        daemonRunning = BattClient.shared.isDaemonRunning
        guard daemonRunning else { return }
        // Sync slider with batt's actual limit, but only when we're not in a user snooze
        // (otherwise the live state of 100% would clobber the saved preference).
        if !isSnoozed, let l = BattClient.shared.readLimit(), [80, 85, 90, 95, 100].contains(l) {
            currentLimit = l
        }
    }

    func startLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.battery = BatteryInfo.current()
        }
    }

    func stopLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // After a limit change the SMC takes a couple seconds to start/stop charging.
    // Poll quickly for a short window so the UI reflects the transition immediately.
    private func pulseFastRefresh(seconds: Double = 6.0) {
        aggressiveTimer?.invalidate()
        let interval = 0.1
        var ticksRemaining = Int(seconds / interval)
        aggressiveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.battery = BatteryInfo.current()
            ticksRemaining -= 1
            if ticksRemaining <= 0 {
                timer.invalidate()
                self.aggressiveTimer = nil
            }
        }
    }

    func selectLimit(_ value: Int) {
        guard battInstalled, daemonRunning else { return }
        currentLimit = value
        UserDefaults.standard.set(value, forKey: savedLimitKey)
        BattClient.shared.setLimit(value)
        // Optimistic UI: predict new charging state immediately so the popup
        // reflects the change before the SMC actually transitions.
        if let cur = battery, cur.isPluggedIn {
            let willCharge = value > cur.percent
            battery = BatteryInfo(
                percent: cur.percent,
                isCharging: willCharge,
                isPluggedIn: cur.isPluggedIn,
                isLowPowerMode: cur.isLowPowerMode
            )
        }
        // Any explicit slider change cancels an in-progress snooze
        midnightTimer?.invalidate()
        midnightTimer = nil
        snoozedUntil = nil
        pulseFastRefresh()
    }

    func disableForToday() {
        guard battInstalled, daemonRunning else { return }
        savedLimitForSnooze = currentLimit
        BattClient.shared.setLimit(100)   // batt treats 100 as disabled
        pulseFastRefresh()

        let calendar = Calendar.current
        let now = Date()
        let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(86400)
        snoozedUntil = nextMidnight

        let savedLimit = savedLimitForSnooze
        midnightTimer?.invalidate()
        midnightTimer = Timer.scheduledTimer(
            withTimeInterval: nextMidnight.timeIntervalSince(now),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            BattClient.shared.setLimit(savedLimit)
            DispatchQueue.main.async {
                self.currentLimit = savedLimit
                self.snoozedUntil = nil
                self.refresh()
            }
        }
    }

    func resumeNow() {
        guard battInstalled, daemonRunning else { return }
        midnightTimer?.invalidate()
        midnightTimer = nil
        BattClient.shared.setLimit(savedLimitForSnooze)
        currentLimit = savedLimitForSnooze
        snoozedUntil = nil
        pulseFastRefresh()
    }
}

// MARK: - UI

struct ChargeLimitView: View {
    @ObservedObject var model: AppModel
    var onDismiss: () -> Void = {}
    @State private var sliderValue: Double = 80
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.battInstalled {
                installPrompt
            } else if !model.daemonRunning {
                daemonPrompt
            } else {
                sliderRow
                batteryRow
                Divider().opacity(0.35)
                bottomRow
                settingsLink
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 260)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            sliderValue = Double(model.currentLimit)
            model.startLiveRefresh()
        }
        .onDisappear { model.stopLiveRefresh() }
        .onChange(of: model.currentLimit) { _, newValue in
            if !isDragging { sliderValue = Double(newValue) }
        }
    }

    private var sliderRow: some View {
        HStack(spacing: 10) {
            Text("Charge Limit")
                .font(.system(size: 13))
                .fixedSize()
                .foregroundColor(.primary)
            Slider(
                value: $sliderValue,
                in: 80...100,
                step: 5,
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        model.selectLimit(Int(sliderValue))
                    }
                }
            )
            .controlSize(.small)
            Text("\(Int(sliderValue))%")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
        }
    }

    private var batteryRow: some View {
        HStack(spacing: 6) {
            if let b = model.battery {
                Image(systemName: b.symbolName)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text("\(b.percent)%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Spacer()
                Text(b.statusLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text("Battery info unavailable")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            Text("Turn off for today")
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.isSnoozed },
                set: { newValue in
                    if newValue { model.disableForToday() } else { model.resumeNow() }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var settingsLink: some View {
        Button {
            openBatterySettings()
            onDismiss()
        } label: {
            HStack(spacing: 4) {
                Text("Battery Settings…")
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
    }

    private func openBatterySettings() {
        // Tahoe / Ventura+ pane identifier; falls back to legacy URL on older systems.
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery",
        ]
        for str in candidates {
            if let url = URL(string: str), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private var daemonPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("`batt` daemon not running")
                .font(.system(size: 12, weight: .semibold))
            Text("Run this once in Terminal to install and start the daemon:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("sudo brew services start batt")
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                )
            Text("Then turn off System Settings → Battery → Battery Health for the limit to take effect.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sudo brew services start batt", forType: .string)
                } label: { Text("Copy command") }
                Button("Recheck") { model.refresh() }
            }
            .controlSize(.small)
        }
    }

    private var installPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("`batt` is not installed")
                .font(.system(size: 12, weight: .semibold))
            Text("This app uses the open-source `batt` daemon to control charging on Apple Silicon.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("brew install batt")
                Text("sudo brew services start batt")
                    .help("Starts the privileged daemon that controls charging")
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
            )
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install batt && sudo brew services start batt", forType: .string)
                } label: {
                    Text("Copy install command")
                }
                Button("Recheck") { model.refresh() }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - App delegate (status item + dropdown window)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var eventMonitor: Any?
    private let model = AppModel()
    private var iconRefreshTimer: Timer?
    private var iopsRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        if let btn = statusItem.button {
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(togglePopup(_:))
        }

        refreshMenuBarIcon()

        // React to Low Power Mode changes immediately
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuBarIcon),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )

        // React to power source changes (plug/unplug, charging start/stop)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refreshMenuBarIcon() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            iopsRunLoopSource = source
        }

        // Safety-net poll for battery-level changes (events above cover most cases)
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshMenuBarIcon()
        }
    }

    @objc private func refreshMenuBarIcon() {
        guard let btn = statusItem?.button else { return }
        let info = BatteryInfo.current()
        model.battery = info
        if let info {
            btn.toolTip = "\(info.percent)% — \(info.statusLabel)"
            if let img = MenuBarIcon.image(for: info) {
                btn.image = img
            }
        } else {
            let fb = NSImage(systemSymbolName: "battery.100", accessibilityDescription: "Battery")
            fb?.isTemplate = true
            btn.image = fb
            btn.toolTip = "Battery info unavailable"
        }
    }

    @objc private func togglePopup(_ sender: Any?) {
        if let w = window, w.isVisible {
            closePopup()
            return
        }
        showPopup()
    }

    private func showPopup() {
        model.refresh()

        let cornerRadius: CGFloat = 18

        let host = NSHostingView(rootView: ChargeLimitView(model: model, onDismiss: { [weak self] in
            self?.closePopup()
        }))
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.level = .statusBar
        win.isMovable = false

        // Add visual material under the SwiftUI content
        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visual.material = .menu
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true
        visual.autoresizingMask = [.width, .height]

        // Explicit CAShapeLayer mask — corner-radius alone sometimes lets the
        // vibrancy effect bleed past the rounded edge on Tahoe.
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(roundedRect: visual.bounds,
                                cornerWidth: cornerRadius,
                                cornerHeight: cornerRadius,
                                transform: nil)
        visual.layer?.mask = maskLayer

        host.frame = visual.bounds
        visual.addSubview(host)
        win.contentView = visual

        guard let btn = statusItem.button,
              let btnWindow = btn.window,
              let screen = btnWindow.screen else { return }
        let btnInWindow = btn.convert(btn.bounds, to: nil)
        let btnOnScreen = btnWindow.convertToScreen(btnInWindow)
        let screenMaxX = screen.visibleFrame.maxX
        let x = max(4, min(btnOnScreen.midX - size.width / 2, screenMaxX - size.width - 4))
        let y = btnOnScreen.minY - size.height - 4
        win.setFrameOrigin(NSPoint(x: x, y: y))
        win.makeKeyAndOrderFront(nil)
        // Recompute the window shadow from the rounded content's alpha — without this,
        // the shadow is a hard rectangle that shows behind the rounded corners.
        win.invalidateShadow()
        window = win

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopup()
        }
    }

    private func closePopup() {
        window?.orderOut(nil)
        window = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
