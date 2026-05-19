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

    func readLimit() -> Int? {
        let result = run(["status"])
        for raw in result.output.split(separator: "\n") {
            let line = String(raw)
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

// MARK: - Low Power Mode (pmset wrapper)

extension Notification.Name {
    // Posted by the model when an LPM toggle needs first-time consent. The
    // AppDelegate listens, closes the dropdown, and presents an explanatory
    // alert before any admin dialog. userInfo: "enabled" Bool, "previous" Bool.
    static let chargeLimitNeedsLPMConsent = Notification.Name("ChargeLimit.NeedsLPMConsent")
}

enum PowerManager {
    static let sudoersPath = "/etc/sudoers.d/chargelimit-pmset"

    // True when the sudoers entry we install ourselves is in place — we can
    // toggle LPM with no prompt. `sudo -n -l <cmd>` is NOT reliable here: it
    // returns success for any command the user could run after typing a
    // password, not specifically for NOPASSWD entries. Checking for our file
    // is the only definitive signal that we set up passwordless access.
    static var hasPasswordlessAccess: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    // Silent path. Only call when hasPasswordlessAccess is true.
    static func setLowPowerModeSilently(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        let value = enabled ? 1 : 0
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", "\(value)"]
            let null = Pipe()
            task.standardOutput = null
            task.standardError = null
            var success = false
            do {
                try task.run()
                task.waitUntilExit()
                success = task.terminationStatus == 0
            } catch {}
            DispatchQueue.main.async { completion(success) }
        }
    }

    // First-time setup: admin prompt installs a sudoers entry scoped to ONLY
    // `pmset -a lowpowermode 0|1` for this user, AND toggles LPM in the same
    // admin context (so just one auth dialog). MUST only be called after
    // explicit in-app consent — never as the silent fallback of an LPM toggle.
    static func installSudoersAndSet(enabled: Bool, completion: @escaping (Bool) -> Void) {
        let value = enabled ? 1 : 0
        let username = NSUserName()
        // Sudoers files MUST end with a newline — visudo rejects entries that
        // don't, which was silently failing the previous temp-file+visudo dance.
        // We also write the file directly via `tee` (running as root) so there's
        // no middle step that can fail without surfacing an error.
        let entry = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1\n"
        // Inside an AppleScript double-quoted string we can't safely embed
        // arbitrary single quotes either, so base64-encode the entry and decode
        // it on the other side. Same trick the macOS docs recommend for
        // `do shell script` payloads with funky characters.
        let entryB64 = Data(entry.utf8).base64EncodedString()
        let bash = "set -e; "
            + "echo \(entryB64) | /usr/bin/base64 -D | /usr/bin/tee \(sudoersPath) > /dev/null; "
            + "/bin/chmod 440 \(sudoersPath); "
            + "/usr/sbin/chown root:wheel \(sudoersPath); "
            + "/usr/sbin/visudo -cf \(sudoersPath) > /dev/null; "
            + "/usr/bin/pmset -a lowpowermode \(value)"
        let source = "do shell script \"\(bash)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            if let appleScript = NSAppleScript(source: source) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if let error {
                    NSLog("ChargeLimit: installSudoersAndSet AppleScript error: \(error)")
                } else {
                    success = true
                }
            }
            // Verify the file actually landed — AppleScript can return success
            // for partial failures in some cases.
            let installed = FileManager.default.fileExists(atPath: sudoersPath)
            if success && !installed {
                NSLog("ChargeLimit: installSudoersAndSet returned success but file is missing at \(sudoersPath)")
            }
            DispatchQueue.main.async { completion(success && installed) }
        }
    }
}

// MARK: - Battery info (IOKit)

struct BatteryInfo: Equatable {
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
        let value = max(0.0, min(1.0, Double(info.percent) / 100.0))

        // Plugged-in symbols include Apple's own bolt overlay as a third
        // hierarchical layer — we color it explicitly so the bolt is always
        // legible against the fill color (the old custom cutout drew a
        // bolt-shaped hole which read as dark-on-green and was unreadable).
        let baseName = info.isPluggedIn ? "battery.100percent.bolt" : "battery.0to100"
        var battery = NSImage(systemSymbolName: baseName,
                              variableValue: value,
                              accessibilityDescription: "Battery: \(info.percent)%")
        if battery == nil {
            // Older systems without the variable-value bolt symbol — pick the
            // closest discrete step.
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

        // Apple's menu bar palette: outline stays muted, fill takes the state color.
        //  - red ≤20%
        //  - yellow on Low Power Mode
        //  - green when actively charging
        //  - neutral (label color) when held at the limit or on battery
        let outlineColor: NSColor = .secondaryLabelColor
        let fillColor: NSColor
        let useTemplate: Bool
        if info.percent <= 20 {
            fillColor = .systemRed;    useTemplate = false
        } else if info.isLowPowerMode {
            fillColor = .systemYellow; useTemplate = false
        } else if info.isCharging {
            fillColor = .systemGreen;  useTemplate = false
        } else {
            fillColor = .labelColor;   useTemplate = !info.isPluggedIn
        }

        let sizeConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let finalConfig: NSImage.SymbolConfiguration
        if useTemplate {
            finalConfig = sizeConfig
        } else {
            // For the bolt symbol the third palette color paints the bolt itself.
            // White reads on every colored fill (red/green/yellow); for the
            // neutral plugged-in-not-charging case we use labelColor so the bolt
            // matches the fill and adapts to dark/light mode.
            let boltColor: NSColor = (fillColor == .labelColor) ? .labelColor : .white
            let palette: [NSColor] = info.isPluggedIn
                ? [outlineColor, fillColor, boltColor]
                : [outlineColor, fillColor]
            finalConfig = sizeConfig.applying(
                NSImage.SymbolConfiguration(paletteColors: palette)
            )
        }
        battery = battery?.withSymbolConfiguration(finalConfig)

        battery?.isTemplate = useTemplate
        return battery
    }
}

// MARK: - Model

final class AppModel: ObservableObject {
    @Published var currentLimit: Int = 80
    @Published var snoozedUntil: Date? = nil
    @Published var battInstalled: Bool = false
    @Published var daemonRunning: Bool = false
    @Published var battery: BatteryInfo? = nil
    @Published var lowPowerMode: Bool = false
    @Published var lastError: String? = nil

    var isSnoozed: Bool { snoozedUntil != nil }

    private var midnightTimer: Timer?
    private var refreshTimer: Timer?
    private var safetyTimer: Timer?
    private var aggressiveTimer: Timer?
    private var iopsRunLoopSource: CFRunLoopSource?
    private var optimisticUntil: Date?
    private var savedLimitForSnooze: Int = 80
    private let savedLimitKey = "ChargeLimit.savedLimit"
    private let snoozeUntilKey = "ChargeLimit.snoozeUntil"
    private let snoozeSavedLimitKey = "ChargeLimit.snoozeSavedLimit"

    init() {
        let saved = UserDefaults.standard.integer(forKey: savedLimitKey)
        if [80, 85, 90, 95, 100].contains(saved) {
            currentLimit = saved
        }
        // Restore in-flight snooze across relaunches.
        let savedSnoozeLimit = UserDefaults.standard.integer(forKey: snoozeSavedLimitKey)
        if [80, 85, 90, 95, 100].contains(savedSnoozeLimit) {
            savedLimitForSnooze = savedSnoozeLimit
        }
        if let until = UserDefaults.standard.object(forKey: snoozeUntilKey) as? Date {
            if until > Date() {
                snoozedUntil = until
                scheduleMidnightTimer(fireAt: until)
            } else {
                BattClient.shared.setLimit(savedLimitForSnooze)
                currentLimit = savedLimitForSnooze
                UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
                UserDefaults.standard.removeObject(forKey: snoozeSavedLimitKey)
            }
        }
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        setupPowerObservers()
        refresh()
    }

    private func setupPowerObservers() {
        // IOPS callback — fires on plug/unplug AND charging start/stop. Without
        // this the menu bar only updated on the 30s safety poll, so plug events
        // could lag noticeably.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<AppModel>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refreshBattery() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            iopsRunLoopSource = source
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.refreshBattery()
        }

        // IOPS notifications cover plug/unplug and charging start/stop, which are
        // the events that change the icon's color/bolt. Percent drifts slowly,
        // so a 5-minute safety poll is plenty to keep the icon honest without
        // waking the process every 30s.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    // Reads IOKit, but during the post-limit-change window we hold the predicted
    // state until the SMC catches up — otherwise the dropdown flashes "plugged in,
    // not charging" for 2-3 seconds while the controller transitions.
    func refreshBattery() {
        let smc = BatteryInfo.current()
        let now = Date()
        if let until = optimisticUntil, now < until,
           let s = smc, let cur = battery,
           s.isCharging != cur.isCharging {
            return
        }
        battery = smc
        if let until = optimisticUntil, now >= until {
            optimisticUntil = nil
        }
    }

    func refresh() {
        // Fast, main-thread-only work: filesystem + IOKit reads.
        battInstalled = BattClient.shared.isInstalled
        refreshBattery()
        guard battInstalled else { daemonRunning = false; return }
        // Shelling out to `batt` blocks for a few hundred ms — keep it off the
        // main thread so opening the popup doesn't hitch.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let running = BattClient.shared.isDaemonRunning
            let liveLimit: Int? = running ? BattClient.shared.readLimit() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.daemonRunning = running
                if !self.isSnoozed, let l = liveLimit, [80, 85, 90, 95, 100].contains(l) {
                    self.currentLimit = l
                }
            }
        }
    }

    func startLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    func stopLiveRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func pulseFastRefresh(seconds: Double = 5.0) {
        aggressiveTimer?.invalidate()
        let interval = 0.15
        var ticksRemaining = Int(seconds / interval)
        aggressiveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.refreshBattery()
            ticksRemaining -= 1
            if ticksRemaining <= 0 {
                timer.invalidate()
                self.aggressiveTimer = nil
            }
        }
    }

    private func setOptimistic(isCharging: Bool) {
        guard let cur = battery, cur.isPluggedIn else { return }
        battery = BatteryInfo(
            percent: cur.percent,
            isCharging: isCharging,
            isPluggedIn: cur.isPluggedIn,
            isLowPowerMode: cur.isLowPowerMode
        )
        optimisticUntil = Date().addingTimeInterval(4.0)
    }

    func selectLimit(_ value: Int) {
        guard battInstalled, daemonRunning else { return }
        currentLimit = value
        UserDefaults.standard.set(value, forKey: savedLimitKey)
        BattClient.shared.setLimit(value)
        if let cur = battery, cur.isPluggedIn {
            setOptimistic(isCharging: value > cur.percent)
        }
        midnightTimer?.invalidate()
        midnightTimer = nil
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        UserDefaults.standard.removeObject(forKey: snoozeSavedLimitKey)
        pulseFastRefresh()
    }

    func disableForToday() {
        guard battInstalled, daemonRunning else { return }
        if !isSnoozed { savedLimitForSnooze = currentLimit }
        BattClient.shared.setLimit(100)
        if let cur = battery, cur.isPluggedIn {
            setOptimistic(isCharging: cur.percent < 100)
        }
        pulseFastRefresh()

        let calendar = Calendar.current
        let now = Date()
        let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(86400)
        snoozedUntil = nextMidnight

        UserDefaults.standard.set(nextMidnight, forKey: snoozeUntilKey)
        UserDefaults.standard.set(savedLimitForSnooze, forKey: snoozeSavedLimitKey)
        scheduleMidnightTimer(fireAt: nextMidnight)
    }

    func resumeNow() {
        guard battInstalled, daemonRunning else { return }
        midnightTimer?.invalidate()
        midnightTimer = nil
        BattClient.shared.setLimit(savedLimitForSnooze)
        currentLimit = savedLimitForSnooze
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        UserDefaults.standard.removeObject(forKey: snoozeSavedLimitKey)
        if let cur = battery, cur.isPluggedIn {
            setOptimistic(isCharging: savedLimitForSnooze > cur.percent)
        }
        pulseFastRefresh()
    }

    private func scheduleMidnightTimer(fireAt date: Date) {
        midnightTimer?.invalidate()
        let savedLimit = savedLimitForSnooze
        midnightTimer = Timer.scheduledTimer(
            withTimeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            BattClient.shared.setLimit(savedLimit)
            DispatchQueue.main.async {
                self.currentLimit = savedLimit
                self.snoozedUntil = nil
                UserDefaults.standard.removeObject(forKey: self.snoozeUntilKey)
                UserDefaults.standard.removeObject(forKey: self.snoozeSavedLimitKey)
                self.refresh()
            }
        }
    }

    func setLowPowerMode(_ enabled: Bool) {
        let previous = lowPowerMode
        lowPowerMode = enabled  // optimistic — reconciled below or via system notification

        if PowerManager.hasPasswordlessAccess {
            PowerManager.setLowPowerModeSilently(enabled) { [weak self] success in
                guard let self else { return }
                if success {
                    self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                } else {
                    // Sudoers file is present but sudo refused — most likely the
                    // file was edited or removed externally. Roll back the
                    // optimistic UI and fall through to the consent path so the
                    // user can re-grant or cancel.
                    self.lowPowerMode = previous
                    NotificationCenter.default.post(
                        name: .chargeLimitNeedsLPMConsent,
                        object: nil,
                        userInfo: ["enabled": enabled, "previous": previous]
                    )
                }
            }
        } else {
            // Defer to the AppDelegate to show the consent alert. Keeps UI
            // concerns out of the model, and lets the delegate close the
            // dropdown first (NSAlert won't show above a popUpMenu window).
            NotificationCenter.default.post(
                name: .chargeLimitNeedsLPMConsent,
                object: nil,
                userInfo: ["enabled": enabled, "previous": previous]
            )
        }
    }

    func confirmFirstTimeLPM(enable: Bool) {
        PowerManager.installSudoersAndSet(enabled: enable) { [weak self] _ in
            guard let self else { return }
            self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    func cancelFirstTimeLPM(previous: Bool) {
        lowPowerMode = previous
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
                lowPowerRow
                bottomRow
                settingsLink
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 260)
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

    private var lowPowerRow: some View {
        HStack(spacing: 8) {
            Text("Low Power Mode")
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.lowPowerMode },
                set: { model.setLowPowerMode($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
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
            .help("Disables the charge limit until midnight, then automatically restores your saved value.")
        }
    }

    private var settingsLink: some View {
        Button {
            openBatterySettings()
            onDismiss()
        } label: {
            HStack(spacing: 4) {
                Text("Battery Settings")
                    .font(.system(size: 13))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
    }

    private func openBatterySettings() {
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

// MARK: - Rounded mask image for the visual effect view
//
// Apple's documented recipe for a rounded NSVisualEffectView: build a 9-slice
// stretchable NSImage of a filled rounded rect and assign it to `maskImage`.
// Unlike CAShapeLayer/CALayer masks, this is what the window-server uses to
// compute `hasShadow`, so the drop shadow follows the rounded corners exactly
// instead of rendering as a rectangle behind the popup.
private func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
    let edge: CGFloat = cornerRadius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.setFill()
        path.fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                   bottom: cornerRadius, right: cornerRadius)
    image.resizingMode = .stretch
    return image
}

// MARK: - App delegate (status item + dropdown window)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var eventMonitor: Any?
    private var localKeyMonitor: Any?
    private let model = AppModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshMenuBarIcon()

        // The model owns power-state observation; the icon just reacts to changes.
        model.$battery
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)

        model.$lowPowerMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)

        // Tooltip includes the configured limit and snooze state, so refresh
        // when either changes.
        model.$currentLimit
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)

        model.$snoozedUntil
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: .chargeLimitNeedsLPMConsent,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let enabled = (note.userInfo?["enabled"] as? Bool) ?? false
            let previous = (note.userInfo?["previous"] as? Bool) ?? false
            self.askForLPMConsent(enable: enabled, previous: previous)
        }
    }

    private func askForLPMConsent(enable: Bool, previous: Bool) {
        closePopup()

        let alert = NSAlert()
        alert.messageText = "Allow Low Power Mode without prompting?"
        alert.informativeText = """
        macOS requires administrator privileges to change Low Power Mode. To avoid prompting on every toggle, ChargeLimit can install a one-time permission rule that lets only these two exact commands run without a password:

            sudo pmset -a lowpowermode 0
            sudo pmset -a lowpowermode 1

        The rule lives at \(PowerManager.sudoersPath) and is scoped to your user account. To remove it later, run:

            sudo rm \(PowerManager.sudoersPath)

        Continuing will show the macOS admin authentication dialog once. After that, the LPM toggle works silently.
        """
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            model.confirmFirstTimeLPM(enable: enable)
        } else {
            model.cancelFirstTimeLPM(previous: previous)
        }
    }

    @objc private func refreshMenuBarIcon() {
        guard let btn = statusItem?.button else { return }
        if let info = model.battery {
            let limitText: String
            if let until = model.snoozedUntil {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                limitText = "Limit off until \(formatter.string(from: until))"
            } else {
                limitText = "Limit \(model.currentLimit)%"
            }
            btn.toolTip = "\(info.percent)% — \(info.statusLabel) · \(limitText)"
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

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRight {
            showContextMenu()
            return
        }
        togglePopup(sender)
    }

    @objc private func togglePopup(_ sender: Any?) {
        if let w = window, w.isVisible {
            closePopup()
            return
        }
        showPopup()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open ChargeLimit", action: #selector(togglePopup(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ChargeLimit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showPopup() {
        model.refresh()

        let cornerRadius: CGFloat = 12

        let host = NSHostingView(rootView: ChargeLimitView(model: model, onDismiss: { [weak self] in
            self?.closePopup()
        }))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        // .popUpMenu matches the system menu-bar dropdown level — `.statusBar`
        // sits above ordinary modals, which makes the popup feel intrusive.
        win.level = .popUpMenu
        win.isMovable = false
        win.hidesOnDeactivate = false

        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visual.material = .menu
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.autoresizingMask = [.width, .height]
        // Use Apple's documented rounded-popover recipe: a 9-slice mask image.
        // This is what makes `win.hasShadow` produce a rounded shadow — layer
        // masks (CAShapeLayer / CALayer) clip the visible pixels but the
        // window-server's shadow path doesn't honor them, so the shadow comes
        // out as a hard rectangle. `maskImage` fixes both at once.
        visual.maskImage = roundedMaskImage(cornerRadius: cornerRadius)

        host.frame = visual.bounds
        host.autoresizingMask = [.width, .height]
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
        win.invalidateShadow()
        window = win

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopup()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePopup()
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: win
        )
    }

    @objc private func handleWindowResignKey(_ note: Notification) {
        closePopup()
    }

    private func closePopup() {
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: w)
        }
        window?.orderOut(nil)
        window = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
