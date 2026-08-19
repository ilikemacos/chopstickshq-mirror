#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
echo "🚀 Fathom Installer"
if [[ ! -f "$0" ]]; then echo "❌ Save script to disk first."; exit 1; fi
[[ "$(uname)" == "Darwin" ]] || { echo "❌ macOS only"; exit 1; }
[[ "${EUID:-$(id -u)}" -ne 0 ]] || { echo "❌ no root"; exit 1; }
_ARCH="$(uname -m)"
[[ "$_ARCH" == "arm64" || "$_ARCH" == "x86_64" ]] || exit 1
for bin in shasum xcode-select swiftc codesign open mktemp base64; do command -v "$bin" >/dev/null || { echo "missing $bin"; exit 1; }; done
EXPECTED_HASH="467bdda9933880b3c56f8447b94218315b1a7bb91a3d8cf834f7959c84f7e4a1"
ACTUAL_HASH="$(sed 's/^EXPECTED_HASH=.*/EXPECTED_HASH="MASKED"/' "$0" | shasum -a 256 | awk '{print $1}')"
[[ "$ACTUAL_HASH" == "$EXPECTED_HASH" ]] || { echo "❌ integrity fail"; exit 1; }
echo "✅ Integrity check passed."
xcode-select -p &>/dev/null || { echo "❌ xcode-select --install"; exit 1; }
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fathom-build.XXXXXXXX")"
APP_DEST="$HOME/Applications/Fathom.app"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT INT TERM
chmod 700 "$WORK_DIR"
cat > "$WORK_DIR/main.swift" << 'SWIFTEOF'
import Cocoa
import SwiftUI
import Combine
import Darwin
import IOKit
import IOKit.ps
import UserNotifications

let FATHOM_VERSION = "v0.2.13-Beta"
let FATHOM_CHANNEL = "beta"
let kReplaceSystemBattery = "fathom.replaceSystemBattery"
let kMenuBarPosition = "fathom.menuBarPosition"
let kMenuBarAutosaveName = "FathomBattery"
let kMenuBarDisplayMode = "fathom.menuBarDisplayMode"
let kDrainAlertsEnabled = "fathom.drainAlerts.enabled"
let kDrainAlertsDropPercent = "fathom.drainAlerts.dropPercent"
let kDrainAlertsWindowMinutes = "fathom.drainAlerts.windowMinutes"
let kWattHistorySlots = 1800
let kDashboardPrefs = "fathom.dashboard.prefs.v1"

extension Notification.Name {
    static let fathomRebuildStatusItem = Notification.Name("fathom.rebuildStatusItem")
    static let fathomOpenDashboard = Notification.Name("fathom.openDashboard")
    static let fathomMenuBarDisplayChanged = Notification.Name("fathom.menuBarDisplayChanged")
    static let fathomDashboardPrefsChanged = Notification.Name("fathom.dashboardPrefsChanged")
}

enum MenuBarDisplayMode: String {
    case percent
    case watts

    static var current: MenuBarDisplayMode {
        let raw = UserDefaults.standard.string(forKey: kMenuBarDisplayMode) ?? "percent"
        return MenuBarDisplayMode(rawValue: raw) ?? .percent
    }

    static func set(_ mode: MenuBarDisplayMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: kMenuBarDisplayMode)
        NotificationCenter.default.post(name: .fathomMenuBarDisplayChanged, object: nil)
    }
}
let UPDATE_CHECK_URL = URL(string: "https://chopstickshq.com/fathom/version.json")!
let UPDATE_PAGE_URL = URL(string: "https://chopstickshq.com/fathom/")!
let UPDATE_CDN_BASE = "https://chopstickshq.com/fathom"
let SUPPORT_DIR: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fathom", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let RNITRO_SITE_URL = URL(string: "https://chopstickshq.com/macbar/")!
let RNITRO_BUNDLE_ID = "com.chopstickshq.rnitro"

enum RNitroLink {
    static var isInstalled: Bool {
        if #available(macOS 12.0, *),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: RNITRO_BUNDLE_ID) != nil {
            return true
        }
        let paths = [
            "\(NSHomeDirectory())/Applications/MacBar.app",
            "/Applications/MacBar.app",
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func openOrInstall() {
        if #available(macOS 12.0, *),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RNITRO_BUNDLE_ID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return
        }
        for p in ["\(NSHomeDirectory())/Applications/MacBar.app", "/Applications/MacBar.app"] {
            if FileManager.default.fileExists(atPath: p) {
                NSWorkspace.shared.open(URL(fileURLWithPath: p))
                return
            }
        }
        NSWorkspace.shared.open(RNITRO_SITE_URL)
    }
}

extension Color {
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let card = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let cardElevated = Color(red: 0.19, green: 0.19, blue: 0.20)
    static let border = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.08)
    static let labelPrimary = Color.white.opacity(0.92)
    static let labelSecondary = Color.white.opacity(0.48)
    static let labelTertiary = Color.white.opacity(0.32)
    static let accent = Color.white.opacity(0.92)
    static let nGreen = Color.white.opacity(0.78)
    static let nOrange = Color.white.opacity(0.62)
    static let nRed = Color.white.opacity(0.88)
    static let nPurple = Color.white.opacity(0.70)
}

func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .default)
}
func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

struct MonitorRow: View {
    let label: String
    let value: String
    var valueColor: Color = .labelPrimary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(uiFont(13, weight: .regular))
                .foregroundColor(.labelSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(uiFont(13, weight: .medium))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 5)
    }
}

struct MinimalButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(uiFont(12, weight: .medium))
                .foregroundColor(.labelPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct MenuHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.divider)
            .frame(height: 0.5)
            .padding(.vertical, 2)
    }
}

struct MonitorSection<Content: View>: View {
    let title: String
    let accent: Color
    let summary: String
    var sparkline: [Double]? = nil
    let storageKey: String
    var icon: String = "circle.fill"
    @ViewBuilder let content: () -> Content
    @AppStorage private var isExpanded: Bool

    init(title: String, accent: Color, summary: String, sparkline: [Double]? = nil,
         storageKey: String, defaultExpanded: Bool = true, icon: String = "circle.fill",
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.summary = summary
        self.sparkline = sparkline
        self.storageKey = storageKey
        self.icon = icon
        self.content = content
        self._isExpanded = AppStorage(wrappedValue: defaultExpanded, storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.labelSecondary)
                        .frame(width: 18, alignment: .center)
                    Text(title.capitalized)
                        .font(uiFont(13, weight: .semibold))
                        .foregroundColor(.labelPrimary)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(uiFont(12, weight: .regular))
                        .foregroundColor(.labelSecondary)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.labelTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                MenuHairline()
                    .padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 2) {
                    if let sparkline, !sparkline.isEmpty {
                        Sparkline(values: sparkline, color: .labelSecondary)
                            .frame(height: 32)
                            .padding(.bottom, 6)
                            .padding(.top, 2)
                    }
                    content()
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.border, lineWidth: 0.5)
        )
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .labelSecondary
    var body: some View {
        GeometryReader { g in
            let vals = values.isEmpty ? [0.0] : values
            let maxV = max(vals.max() ?? 1, 0.001)
            Path { p in
                for (i, v) in vals.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(vals.count - 1, 1))
                    let y = g.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }
    }
}

@_silgen_name("IOReportCopyAllChannels")
private func IOReportCopyAllChannels(_ a: UInt64, _ b: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ item: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ item: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ item: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ b: CFMutableDictionary,
                                        _ out: UnsafeMutablePointer<CFMutableDictionary?>,
                                        _ flags: UInt64, _ opts: UnsafeRawPointer?) -> UnsafeMutableRawPointer?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ sub: UnsafeMutableRawPointer, _ chan: CFMutableDictionary,
                                   _ opts: UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ a: CFDictionary, _ b: CFDictionary,
                                        _ opts: UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ item: CFDictionary, _ index: Int32) -> Int64

struct SocPowerSample {
    var cpuWatts: Double = 0
    var gpuWatts: Double = 0
    var aneWatts: Double = 0
    var hasData: Bool { cpuWatts > 0 || gpuWatts > 0 || aneWatts > 0 }
    var totalWatts: Double { cpuWatts + gpuWatts + aneWatts }
}

fileprivate final class IOReportPowerReader {
    static let shared = IOReportPowerReader()
    private enum ChannelKind { case cpu, gpu, ane }
    private struct ChannelMeta { let kind: ChannelKind; let unit: String }
    private let queue = DispatchQueue(label: "fathom.ioreport", qos: .utility)
    private(set) var isAvailable = false
    private var allChannels: CFDictionary?
    private var subscription: UnsafeMutableRawPointer?
    private var sampleChannels: CFMutableDictionary?
    private var channels: [ChannelMeta] = []
    private var prevSample: Unmanaged<CFDictionary>?
    private var prevTime: CFAbsoluteTime = 0
    private var permanentlyDisabled = false
    private init() { setup() }
    private func cfStr(_ ref: Unmanaged<CFString>?) -> String {
        guard let ref else { return "" }
        return ref.takeUnretainedValue() as String
    }
    private func energyDeltaToWatts(_ delta: Double, unit: String, durationMs: Double) -> Double {
        let joules: Double
        switch unit {
        case "mJ": joules = delta / 1e3
        case "uJ": joules = delta / 1e6
        case "nJ": joules = delta / 1e9
        default: return 0
        }
        return joules / max(durationMs / 1000.0, 0.001)
    }
    private func deltaChannelItems(_ delta: CFDictionary) -> [CFDictionary] {
        let key = "IOReportChannels" as CFString
        guard let ptr = CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque()) else { return [] }
        let arr = unsafeBitCast(ptr, to: CFArray.self)
        let n = CFArrayGetCount(arr)
        return (0..<n).map { i in unsafeBitCast(CFArrayGetValueAtIndex(arr, i)!, to: CFDictionary.self) }
    }
    private func channelKind(group: String, channel: String) -> ChannelKind? {
        guard group == "Energy Model" else { return nil }
        if channel.hasSuffix("CPU Energy") { return .cpu }
        if channel == "GPU Energy" { return .gpu }
        if channel.hasPrefix("ANE") { return .ane }
        return nil
    }
    private func disablePermanently() {
        permanentlyDisabled = true
        isAvailable = false
    }
    private func setup() {
        guard let allRaw = IOReportCopyAllChannels(0, 0)?.takeRetainedValue() else { return }
        let channelsKey = "IOReportChannels" as CFString
        guard let itemsPtr = CFDictionaryGetValue(allRaw, Unmanaged.passUnretained(channelsKey).toOpaque()) else { return }
        let allItems = unsafeBitCast(itemsPtr, to: CFArray.self)
        let itemCount = CFArrayGetCount(allItems)
        guard let selected = CFArrayCreateMutable(kCFAllocatorDefault, 0, nil) else { return }
        var metas: [ChannelMeta] = []
        for i in 0..<itemCount {
            let itemPtr = CFArrayGetValueAtIndex(allItems, i)!
            let item = unsafeBitCast(itemPtr, to: CFDictionary.self)
            let group = cfStr(IOReportChannelGetGroup(item))
            let channel = cfStr(IOReportChannelGetChannelName(item))
            guard let kind = channelKind(group: group, channel: channel) else { continue }
            CFArrayAppendValue(selected, itemPtr)
            let unit = cfStr(IOReportChannelGetUnitLabel(item)).trimmingCharacters(in: .whitespaces)
            metas.append(ChannelMeta(kind: kind, unit: unit))
        }
        guard !metas.isEmpty else { return }
        guard let chan = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, allRaw) else { return }
        CFDictionarySetValue(chan, Unmanaged.passUnretained(channelsKey).toOpaque(),
                             Unmanaged.passUnretained(selected).toOpaque())
        var subInfo: CFMutableDictionary?
        guard let sub = IOReportCreateSubscription(nil, chan, &subInfo, 0, nil) else { return }
        allChannels = allRaw
        subscription = sub
        sampleChannels = chan
        channels = metas
        isAvailable = true
    }
    func sample() -> SocPowerSample? {
        guard isAvailable, !permanentlyDisabled else { return nil }
        return queue.sync { sampleUnsafe() }
    }
    private func sampleUnsafe() -> SocPowerSample? {
        guard let sub = subscription, let chan = sampleChannels else { return nil }
        guard let sample = IOReportCreateSamples(sub, chan, nil)?.takeRetainedValue() else {
            disablePermanently()
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard let prevBox = prevSample else {
            prevSample = Unmanaged.passRetained(sample)
            prevTime = now
            return nil
        }
        let prev = prevBox.takeUnretainedValue()
        let elapsedMs = (now - prevTime) * 1000.0
        var result: SocPowerSample? = nil
        if elapsedMs >= 200, elapsedMs <= 10_000,
           let deltaRaw = IOReportCreateSamplesDelta(prev, sample, nil)?.takeRetainedValue() {
            let deltaItems = deltaChannelItems(deltaRaw)
            var out = SocPowerSample()
            for (j, item) in deltaItems.enumerated() where j < channels.count {
                let val = Double(IOReportSimpleGetIntegerValue(item, 0))
                let w = energyDeltaToWatts(val, unit: channels[j].unit, durationMs: elapsedMs)
                guard w > 0, w < 500 else { continue }
                switch channels[j].kind {
                case .cpu: out.cpuWatts += w
                case .gpu: out.gpuWatts += w
                case .ane: out.aneWatts += w
                }
            }
            if out.hasData { result = out }
        }
        prevBox.release()
        prevSample = Unmanaged.passRetained(sample)
        prevTime = now
        return result
    }
}

final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    @Published var batteryPresent = false
    @Published var levelPercent = 0
    @Published var isCharging = false
    @Published var isOnAC = false
    @Published var chargeWatts: Double = 0
    @Published var packageWatts: Double = 0
    @Published var packageSource: String = "estimate"
    @Published var pCoreShare: Double = 0
    @Published var eCoreShare: Double = 0
    @Published var cycleCount: Int?
    @Published var healthPercent: Int?
    @Published var capacityRaw: Int?
    @Published var designCapacity: Int?
    @Published var timeText = "—"
    @Published var statusText = "—"
    @Published var wattHistory: [Double] = []
    @Published var wattHistorySpark: [Double] = []

    private var timer: Timer?
    private var wattRing = Array(repeating: 0.0, count: kWattHistorySlots)
    private var wattIdx = 0
    private var wattFilled = 0

    private var fastMode = false

    func start() {
        restartTimer(interval: fastMode ? 1.0 : 1.5)
        poll()
    }

    func setFastMode(_ on: Bool) {
        guard fastMode != on else { return }
        fastMode = on
        restartTimer(interval: on ? 1.0 : 1.5)
        if on { poll() }
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let bat = Self.readBattery()
            let pkg = Self.readPackageWattsDetailed()
            let cores = Self.readCoreShares()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyBattery(bat)
                if pkg.watts > 0 {
                    self.packageWatts = pkg.watts
                    self.packageSource = pkg.source
                }
                self.pCoreShare = cores.p
                self.eCoreShare = cores.e
                let n = kWattHistorySlots
                self.wattRing[self.wattIdx % n] = self.packageWatts
                self.wattIdx += 1
                self.wattFilled = min(self.wattFilled + 1, n)
                var hist: [Double] = []
                hist.reserveCapacity(self.wattFilled)
                let start = self.wattIdx - self.wattFilled
                for i in 0..<self.wattFilled {
                    hist.append(self.wattRing[((start + i) % n + n) % n])
                }
                self.wattHistory = hist
                self.wattHistorySpark = Self.downsample(hist, maxPoints: 120)
                DrainLog.shared.recordPower(
                    level: self.levelPercent,
                    packageW: self.packageWatts,
                    chargeW: self.chargeWatts,
                    charging: self.isCharging
                )
                DrainAlertMonitor.shared.evaluate(
                    level: self.levelPercent,
                    onBattery: self.batteryPresent && !self.isOnAC && !self.isCharging
                )
            }
        }
    }

    private static func downsample(_ values: [Double], maxPoints: Int) -> [Double] {
        guard values.count > maxPoints, maxPoints > 1 else { return values }
        var out: [Double] = []
        out.reserveCapacity(maxPoints)
        let step = Double(values.count - 1) / Double(maxPoints - 1)
        for i in 0..<maxPoints {
            let idx = min(Int((Double(i) * step).rounded()), values.count - 1)
            out.append(values[idx])
        }
        return out
    }

    private func applyBattery(_ s: BatSnap) {
        batteryPresent = s.present
        levelPercent = s.level
        isCharging = s.charging
        isOnAC = s.onAC
        chargeWatts = s.chargeW
        cycleCount = s.cycles
        healthPercent = s.health
        capacityRaw = s.rawMax
        designCapacity = s.design
        if !s.present {
            statusText = "No battery"
            timeText = "Desktop / AC"
            return
        }
        if s.charging {
            statusText = String(format: "Charging · %.0f W", s.chargeW)
            if let m = s.minutes, m > 0, m < 65535 {
                timeText = m >= 60 ? String(format: "%dh %dm to full", m / 60, m % 60) : "\(m) min to full"
            } else {
                timeText = "Calculating…"
            }
        } else if s.onAC {
            statusText = s.level >= 100 ? "Full · on AC" : "Plugged in"
            timeText = "On AC power"
        } else {
            statusText = "On battery"
            if let m = s.minutes, m > 0, m < 65535 {
                timeText = m >= 60 ? String(format: "%dh %dm left", m / 60, m % 60) : "\(m) min left"
            } else {
                timeText = "Calculating…"
            }
        }
    }

    struct BatSnap {
        var present = false
        var level = 0
        var charging = false
        var onAC = false
        var chargeW: Double = 0
        var minutes: Int?
        var cycles: Int?
        var health: Int?
        var rawMax: Int?
        var design: Int?
    }

    private static func cfInt(_ v: CFTypeRef?) -> Int? {
        guard let v else { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if CFGetTypeID(v) == CFNumberGetTypeID() {
            var i: Int32 = 0
            CFNumberGetValue(v as! CFNumber, .sInt32Type, &i)
            return Int(i)
        }
        return nil
    }

    private static func cfBool(_ v: CFTypeRef?) -> Bool? {
        guard let v else { return nil }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if CFGetTypeID(v) == CFBooleanGetTypeID() { return CFBooleanGetValue(v as! CFBoolean) }
        return nil
    }

    private static func prop(_ s: io_service_t, _ k: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func propInt(_ s: io_service_t, _ k: String) -> Int? { cfInt(prop(s, k)) }
    private static func propBool(_ s: io_service_t, _ k: String) -> Bool? { cfBool(prop(s, k)) }

    private static func signedMA(_ raw: Int) -> Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: UInt64(bitPattern: Int64(raw)))))
    }

    static func readBattery() -> BatSnap {
        var snap = BatSnap()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                let type = d[kIOPSTypeKey] as? String ?? ""
                if type != kIOPSInternalBatteryType { continue }
                snap.present = true
                if let cap = d[kIOPSCurrentCapacityKey] as? Int { snap.level = min(100, max(0, cap)) }
                if let max = d[kIOPSMaxCapacityKey] as? Int, max > 0, max != 100,
                   let cur = d[kIOPSCurrentCapacityKey] as? Int, cur > 100 {
                    snap.level = min(100, Int(Double(cur) / Double(max) * 100))
                }
                let state = d[kIOPSPowerSourceStateKey] as? String ?? ""
                snap.onAC = state == kIOPSACPowerValue
                snap.charging = (d[kIOPSIsChargingKey] as? Bool) == true
                if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, t < 65535, !snap.charging {
                    snap.minutes = t
                }
                if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, t < 65535, snap.charging {
                    snap.minutes = t
                }
            }
        }

        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSmartBattery"))
        if service == 0 { return snap }
        defer { IOObjectRelease(service) }
        snap.present = true
        if snap.level <= 0 {
            if let cur = propInt(service, "CurrentCapacity"), cur >= 0, cur <= 100 {
                snap.level = cur
            } else if let raw = propInt(service, "AppleRawCurrentCapacity"),
                      let mx = propInt(service, "AppleRawMaxCapacity"), mx > 0 {
                snap.level = min(100, Int((Double(raw) / Double(mx) * 100).rounded()))
            }
        }
        if let c = propBool(service, "IsCharging") { snap.charging = c; if c { snap.onAC = true } }
        if let e = propBool(service, "ExternalConnected") { snap.onAC = e || snap.charging }
        snap.cycles = propInt(service, "CycleCount")
        let design = propInt(service, "DesignCapacity") ?? 0
        let rawMax = propInt(service, "AppleRawMaxCapacity") ?? propInt(service, "NominalChargeCapacity")
        snap.design = design > 0 ? design : nil
        snap.rawMax = rawMax
        if let rawMax, design > 0 {
            snap.health = min(100, Int((Double(rawMax) / Double(design) * 100).rounded()))
        }
        let voltage = propInt(service, "AppleRawBatteryVoltage") ?? propInt(service, "Voltage") ?? 0
        if let amp = propInt(service, "InstantAmperage") ?? propInt(service, "Amperage") {
            let signed = signedMA(amp)
            if signed != 0, voltage > 0 {
                let w = abs(Double(signed)) / 1000.0 * Double(voltage) / 1000.0
                if snap.charging && signed > 0 { snap.chargeW = w }
                else if !snap.charging && signed < 0 { snap.chargeW = w }
            }
        }
        if snap.charging, snap.chargeW <= 0,
           let charger = prop(service, "ChargerData") as? [String: Any],
           let cc = (charger["ChargingCurrent"] as? NSNumber)?.intValue, cc > 0, voltage > 0 {
            snap.chargeW = Double(cc) / 1000.0 * Double(voltage) / 1000.0
        }
        if snap.minutes == nil {
            if snap.charging, let t = propInt(service, "AvgTimeToFull") ?? propInt(service, "TimeRemaining"), t > 0, t < 65535 {
                snap.minutes = t
            } else if !snap.charging, let t = propInt(service, "AvgTimeToEmpty") ?? propInt(service, "TimeRemaining"), t > 0, t < 65535 {
                snap.minutes = t
            }
        }
        return snap
    }

    static func readPackageWattsDetailed() -> (watts: Double, source: String) {
        if let sample = IOReportPowerReader.shared.sample(), sample.cpuWatts > 0.05 {
            return (sample.cpuWatts, "sensor")
        }
        var load = loadavg()
        var sz = MemoryLayout<loadavg>.size
        guard sysctlbyname("vm.loadavg", &load, &sz, nil, 0) == 0, load.fscale > 0 else {
            return (0, "estimate")
        }
        let l1 = Double(load.ldavg.0) / Double(load.fscale)
        var ncpu: Int32 = 1
        var nsz = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &ncpu, &nsz, nil, 0)
        let util = min(1.0, l1 / Double(max(ncpu, 1)))
        return (2.5 + util * 18.0, "estimate")
    }

    static func readPackageWatts() -> Double { readPackageWattsDetailed().watts }

    static func readCoreShares() -> (p: Double, e: Double) {
        var pcores: Int32 = 0
        var ecores: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &pcores, &sz, nil, 0) != 0 {
            pcores = 0
        }
        sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &ecores, &sz, nil, 0) != 0 {
            ecores = 0
        }
        let total = Double(max(1, pcores + ecores))
        if pcores + ecores == 0 {
            return (0.5, 0.5)
        }
        return (Double(pcores) / total, Double(ecores) / total)
    }
}

struct ProcEnergy: Identifiable {
    let id: Int32
    let name: String
    let path: String
    var energyScore: Double
    var cpuPercent: Double
    var samples: [Double]
}

final class ProcessEnergyStore: ObservableObject {
    static let shared = ProcessEnergyStore()
    @Published var top: [ProcEnergy] = []
    private var timer: Timer?
    private var lastCPU: [Int32: Double] = [:]
    private var lastWall = Date()
    private var history: [Int32: [Double]] = [:]
    private let historyCap = 60

    private var fastMode = false

    func start() {
        restartTimer(interval: fastMode ? 1.25 : 2.5)
        sample()
    }

    func setFastMode(_ on: Bool) {
        guard fastMode != on else { return }
        fastMode = on
        restartTimer(interval: on ? 1.25 : 2.5)
        if on { sample() }
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func sample() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let now = Date()
            let dt = max(0.5, now.timeIntervalSince(self.lastWall))
            self.lastWall = now
            var rows: [ProcEnergy] = []
            var nextCPU: [Int32: Double] = [:]

            var pids = [Int32](repeating: 0, count: 4096)
            let bufBytes = Int32(MemoryLayout<Int32>.stride * pids.count)
            let n = proc_listallpids(&pids, bufBytes) / Int32(MemoryLayout<Int32>.stride)
            let count = max(0, min(Int(n), pids.count))
            for i in 0..<count {
                let pid = pids[i]
                if pid <= 0 || pid == getpid() { continue }
                var info = proc_taskallinfo()
                let sz = Int32(MemoryLayout<proc_taskallinfo>.stride)
                guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, sz) == sz else { continue }
                let user = Double(info.ptinfo.pti_total_user) / 1_000_000_000.0
                let sys = Double(info.ptinfo.pti_total_system) / 1_000_000_000.0
                let total = user + sys
                nextCPU[pid] = total
                let prev = self.lastCPU[pid] ?? total
                let delta = max(0, total - prev)
                let cpuPct = min(100, delta / dt * 100.0)
                let threads = Double(info.ptinfo.pti_threadnum)
                let score = cpuPct * 1.0 + min(40, threads) * 0.15
                if score < 0.4 && cpuPct < 0.3 { continue }
                var nameBuf = [CChar](repeating: 0, count: 1024)
                let name: String
                if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
                    name = String(cString: nameBuf)
                } else {
                    name = "pid \(pid)"
                }
                var pathBuf = [CChar](repeating: 0, count: 4096)
                let path: String
                if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
                    path = String(cString: pathBuf)
                } else {
                    path = ""
                }
                var hist = self.history[pid] ?? []
                hist.append(score)
                if hist.count > self.historyCap { hist.removeFirst(hist.count - self.historyCap) }
                self.history[pid] = hist
                rows.append(ProcEnergy(id: pid, name: name, path: path, energyScore: score, cpuPercent: cpuPct, samples: hist))
            }
            self.lastCPU = nextCPU
            rows.sort { $0.energyScore > $1.energyScore }
            let top = Array(rows.prefix(10))
            DispatchQueue.main.async {
                self.top = top
                if let first = top.first {
                    DrainLog.shared.recordTopProcess(name: first.name, score: first.energyScore, cpu: first.cpuPercent)
                }
            }
        }
    }
}

final class DrainLog: ObservableObject {
    static let shared = DrainLog()
    @Published var retentionDays: Int = {
        let v = UserDefaults.standard.integer(forKey: "fathom.retentionDays")
        return v > 0 ? v : 14
    }()

    private let fileURL = SUPPORT_DIR.appendingPathComponent("drain.jsonl")
    private let queue = DispatchQueue(label: "fathom.drainlog")
    private var lastTopName = ""
    private var lastTopScore = 0.0

    func setRetention(_ days: Int) {
        retentionDays = max(1, min(30, days))
        UserDefaults.standard.set(retentionDays, forKey: "fathom.retentionDays")
        prune()
    }

    func recordPower(level: Int, packageW: Double, chargeW: Double, charging: Bool) {
        queue.async {
            let line: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "kind": "power",
                "level": level,
                "packageW": packageW,
                "chargeW": chargeW,
                "charging": charging,
                "top": self.lastTopName,
                "topScore": self.lastTopScore
            ]
            self.append(line)
        }
    }

    func recordEvent(_ name: String) {
        queue.async {
            let line: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "kind": "event",
                "name": name
            ]
            self.append(line)
        }
    }

    func recordTopProcess(name: String, score: Double, cpu: Double) {
        lastTopName = name
        lastTopScore = score
        queue.async {
            let line: [String: Any] = [
                "t": ISO8601DateFormatter().string(from: Date()),
                "kind": "proc",
                "name": name,
                "score": score,
                "cpu": cpu
            ]
            self.append(line)
        }
    }

    private func append(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var str = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        if let d = str.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileURL.path),
               let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: d)
            } else {
                try? d.write(to: fileURL)
            }
        }
        if Int.random(in: 0..<30) == 0 { prune() }
    }

    func prune() {
        queue.async {
            guard let text = try? String(contentsOf: self.fileURL, encoding: .utf8) else { return }
            let cutoff = Date().addingTimeInterval(-Double(self.retentionDays) * 86400)
            let iso = ISO8601DateFormatter()
            var kept: [String] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ts = obj["t"] as? String,
                      let d = iso.date(from: ts), d >= cutoff else { continue }
                kept.append(String(line))
            }
            try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    func clearAll() {
        queue.async { try? FileManager.default.removeItem(at: self.fileURL) }
    }

    struct WhyDrain {
        let dropPercent: Int
        let windowLabel: String
        let culprits: [(name: String, share: Double, note: String)]
        let summary: String
    }

    func whyLastHour() -> WhyDrain {
        let iso = ISO8601DateFormatter()
        let since = Date().addingTimeInterval(-3600)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return WhyDrain(dropPercent: 0, windowLabel: "last hour", culprits: [], summary: "Not enough local history yet — leave Fathom running while on battery.")
        }
        var levels: [(Date, Int)] = []
        var scores: [String: Double] = [:]
        var eventCounts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = obj["t"] as? String,
                  let d = iso.date(from: ts), d >= since else { continue }
            if obj["kind"] as? String == "power", let lv = obj["level"] as? Int {
                levels.append((d, lv))
                if let top = obj["top"] as? String, !top.isEmpty, let sc = obj["topScore"] as? Double {
                    scores[top, default: 0] += sc
                }
            }
            if obj["kind"] as? String == "proc", let n = obj["name"] as? String, let sc = obj["score"] as? Double {
                scores[n, default: 0] += sc
            }
            if obj["kind"] as? String == "event", let n = obj["name"] as? String {
                eventCounts[n, default: 0] += 1
            }
        }
        levels.sort { $0.0 < $1.0 }
        let drop: Int
        if let first = levels.first, let last = levels.last {
            drop = max(0, first.1 - last.1)
        } else {
            drop = 0
        }
        let total = scores.values.reduce(0, +)
        let ranked = scores.sorted { $0.value > $1.value }.prefix(3)
        var culprits: [(String, Double, String)] = []
        for (name, sc) in ranked {
            let share = total > 0 ? sc / total : 0
            culprits.append((name, share, String(format: "%.0f%% of attributed energy samples", share * 100)))
        }
        let summary: String
        if drop <= 0 {
            summary = culprits.isEmpty
                ? "Battery held steady over the last hour (or you were charging)."
                : "Battery held steady. Highest energy activity still logged for reference."
        } else if let top = culprits.first {
            summary = "\(top.0) was responsible for the largest share of energy use while battery dropped ~\(drop)% in the last hour."
        } else {
            summary = "Battery dropped ~\(drop)% in the last hour, but no dominant process was logged yet."
        }
        var notes: [String] = []
        if (eventCounts["display_wake"] ?? 0) >= 2 {
            notes.append("Display woke \(eventCounts["display_wake"]!)× in this window")
        }
        if (eventCounts["display_sleep"] ?? 0) >= 1 {
            notes.append("Display slept \(eventCounts["display_sleep"]!)×")
        }
        if (eventCounts["system_sleep"] ?? 0) >= 1 {
            notes.append("System sleep recorded")
        }
        var fullSummary = summary
        if !notes.isEmpty {
            fullSummary += " " + notes.joined(separator: ". ") + "."
        }
        return WhyDrain(dropPercent: drop, windowLabel: "last hour", culprits: culprits.map { ($0.0, $0.1, $0.2) }, summary: fullSummary)
    }
}

struct PowerSection: View {
    @ObservedObject var power = PowerStore.shared
    var body: some View {
        let summary: String = {
            if !power.batteryPresent { return String(format: "%.1f W pkg", power.packageWatts) }
            return "\(power.levelPercent)% · \(String(format: "%.1fW", power.packageWatts))"
        }()
        MonitorSection(title: "Power", accent: .accent, summary: summary,
                       sparkline: power.wattHistory, storageKey: "fathom.section.power",
                       icon: "bolt.fill") {
            MonitorRow(label: "Battery", value: power.batteryPresent ? "\(power.levelPercent)%" : "—",
                       valueColor: .accent)
            MonitorRow(label: "Status", value: power.statusText)
            MonitorRow(label: "Time", value: power.timeText, valueColor: .labelSecondary)
            MonitorRow(label: "Package", value: String(format: "%.1f W", power.packageWatts), valueColor: .labelPrimary)
            MonitorRow(label: "Power source",
                       value: power.packageSource == "sensor" ? "IOReport sensor" : "load estimate",
                       valueColor: .labelSecondary)
            if power.isCharging {
                MonitorRow(label: "Charge in", value: String(format: "%.1f W", power.chargeWatts), valueColor: .labelPrimary)
            } else if power.chargeWatts > 0 {
                MonitorRow(label: power.batteryPresent && !power.isOnAC ? "Battery draw" : "Draw",
                           value: String(format: "%.1f W", power.chargeWatts), valueColor: .labelPrimary)
            }
            if let h = power.healthPercent {
                MonitorRow(label: "Health", value: "\(h)%", valueColor: .labelPrimary)
            }
            if let c = power.cycleCount {
                MonitorRow(label: "Cycles", value: "\(c)")
            }
            if let raw = power.capacityRaw, let design = power.designCapacity {
                MonitorRow(label: "Capacity", value: "\(raw) / \(design) mAh")
            }
            MonitorRow(label: "P-cores", value: String(format: "~%.0f%%", power.pCoreShare * 100))
            MonitorRow(label: "E-cores", value: String(format: "~%.0f%%", power.eCoreShare * 100))
            Text("CPU package (60s)")
                .font(uiFont(11, weight: .regular))
                .foregroundColor(.labelTertiary)
                .padding(.top, 6)
        }
    }
}

struct EnergySection: View {
    @ObservedObject var store = ProcessEnergyStore.shared
    @State private var expanded: Int32?
    var body: some View {
        let topName = store.top.first?.name ?? "…"
        MonitorSection(title: "Energy", accent: .nOrange, summary: topName,
                       storageKey: "fathom.section.energy", icon: "cpu") {
            Text("Local energy estimate — not Activity Monitor’s private score.")
                .font(uiFont(11, weight: .regular))
                .foregroundColor(.labelTertiary)
                .padding(.bottom, 4)
            if store.top.isEmpty {
                Text("Sampling processes…")
                    .font(uiFont(13))
                    .foregroundColor(.labelSecondary)
            }
            ForEach(store.top.prefix(8)) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        expanded = expanded == p.id ? nil : p.id
                    } label: {
                        HStack(spacing: 10) {
                            Text(p.name)
                                .font(uiFont(13, weight: .medium))
                                .foregroundColor(.labelPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f", p.energyScore))
                                .font(uiFont(13, weight: .semibold))
                                .foregroundColor(.labelPrimary)
                            Text(String(format: "%.0f%%", p.cpuPercent))
                                .font(uiFont(12, weight: .regular))
                                .foregroundColor(.labelSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    if expanded == p.id {
                        Sparkline(values: p.samples, color: .labelSecondary)
                            .frame(height: 28)
                        Text(p.path.isEmpty ? "pid \(p.id)" : p.path)
                            .font(uiFont(10, weight: .regular))
                            .foregroundColor(.labelTertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

struct WhySection: View {
    @State private var why = DrainLog.shared.whyLastHour()
    var body: some View {
        let summary = why.dropPercent > 0 ? "−\(why.dropPercent)%" : "steady"
        MonitorSection(title: "Why drain?", accent: .nPurple, summary: summary,
                       storageKey: "fathom.section.why", icon: "questionmark.circle") {
            Text(why.summary)
                .font(uiFont(13, weight: .regular))
                .foregroundColor(.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            if why.dropPercent > 0 {
                MonitorRow(label: "Drop", value: "~\(why.dropPercent)% · \(why.windowLabel)", valueColor: .labelPrimary)
            }
            ForEach(Array(why.culprits.enumerated()), id: \.offset) { _, c in
                MonitorRow(label: c.name, value: c.note, valueColor: .labelPrimary)
            }
            MinimalButton(title: "Refresh analysis") {
                why = DrainLog.shared.whyLastHour()
            }
            .padding(.top, 8)
        }
    }
}

struct SettingsSection: View {
    @ObservedObject var log = DrainLog.shared
    @State private var days: Double = Double(DrainLog.shared.retentionDays)
    var body: some View {
        MonitorSection(title: "Settings", accent: .labelSecondary, summary: FATHOM_VERSION,
                       storageKey: "fathom.section.settings", defaultExpanded: false,
                       icon: "gearshape") {
            MonitorRow(label: "Version", value: UpdateChecker.displayLabel(FATHOM_VERSION), valueColor: .labelPrimary)
            MonitorRow(label: "Channel", value: FATHOM_CHANNEL)
            MonitorRow(label: "Install", value: UpdateChecker.installPathLabel())
            HStack(spacing: 8) {
                MinimalButton(title: "Check for Updates") { UpdateChecker.checkManually() }
                MinimalButton(title: "Open website") { NSWorkspace.shared.open(UPDATE_PAGE_URL) }
            }
            .padding(.vertical, 6)
            Text("History retention: \(Int(days)) days")
                .font(uiFont(12, weight: .regular))
                .foregroundColor(.labelSecondary)
            Slider(value: $days, in: 1...30, step: 1)
                .tint(Color.white.opacity(0.55))
                .onChange(of: days) { _, newVal in log.setRetention(Int(newVal)) }
            HStack(spacing: 8) {
                MinimalButton(title: "Clear local history") { log.clearAll() }
                MinimalButton(title: "Reveal data folder") { NSWorkspace.shared.open(SUPPORT_DIR) }
            }
            Text(SUPPORT_DIR.path)
                .font(uiFont(10, weight: .regular))
                .foregroundColor(.labelTertiary)
                .lineLimit(2)
            Text("Local only — no accounts, no telemetry.")
                .font(uiFont(11, weight: .regular))
                .foregroundColor(.labelTertiary)
                .padding(.top, 6)
        }
    }
}

final class DrainAlertMonitor {
    static let shared = DrainAlertMonitor()
    private let lastAlertKey = "fathom.drainAlerts.lastFire"
    private var levelTrail: [(Date, Int)] = []

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: kDrainAlertsEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: kDrainAlertsEnabled)
            if newValue { shared.requestPermission() }
        }
    }

    static var dropPercent: Int {
        get {
            let v = UserDefaults.standard.object(forKey: kDrainAlertsDropPercent) as? Int
            return max(2, min(v ?? 5, 30))
        }
        set { UserDefaults.standard.set(max(2, min(newValue, 30)), forKey: kDrainAlertsDropPercent) }
    }

    static var windowMinutes: Int {
        get {
            let v = UserDefaults.standard.object(forKey: kDrainAlertsWindowMinutes) as? Int
            return max(5, min(v ?? 15, 60))
        }
        set { UserDefaults.standard.set(max(5, min(newValue, 60)), forKey: kDrainAlertsWindowMinutes) }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(level: Int, onBattery: Bool) {
        let now = Date()
        levelTrail.append((now, level))
        let keep = now.addingTimeInterval(-Double(Self.windowMinutes + 5) * 60)
        levelTrail.removeAll { $0.0 < keep }
        guard Self.isEnabled, onBattery else { return }

        let window = TimeInterval(Self.windowMinutes * 60)
        guard let oldest = levelTrail.first(where: { now.timeIntervalSince($0.0) >= window * 0.85 })
                ?? levelTrail.first else { return }
        let drop = oldest.1 - level
        guard drop >= Self.dropPercent else { return }

        if let last = UserDefaults.standard.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(last) < 30 * 60 {
            return
        }
        UserDefaults.standard.set(now, forKey: lastAlertKey)

        let top = ProcessEnergyStore.shared.top.first?.name
        let body: String
        if let top {
            body = "Battery dropped \(drop)% in ~\(Self.windowMinutes) min. Top energy: \(top)."
        } else {
            body = "Battery dropped \(drop)% in ~\(Self.windowMinutes) min while on battery."
        }
        let content = UNMutableNotificationContent()
        content.title = "Fathom · drain alert"
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "fathom.drain.\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

enum BatteryMenuChrome {
    static func openBatterySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery",
            "x-apple.systempreferences:com.apple.settings.Battery",
        ]
        for s in candidates {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
        if let u = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(u)
        }
    }

    static func energyLabel(cpuPercent: Double) -> String {
        if cpuPercent >= 40 { return "High" }
        if cpuPercent >= 12 { return "Moderate" }
        if cpuPercent >= 3 { return "Low" }
        return "Very Low"
    }

    static func batterySymbol(level: Int, charging: Bool, onAC: Bool, present: Bool) -> String {
        if !present { return "powerplug.fill" }
        if charging || (onAC && level < 100) {
            if level >= 95 { return "battery.100.bolt" }
            if level >= 70 { return "battery.75.bolt" }
            if level >= 45 { return "battery.50.bolt" }
            if level >= 20 { return "battery.25.bolt" }
            return "battery.0.bolt"
        }
        if level >= 95 { return "battery.100" }
        if level >= 70 { return "battery.75" }
        if level >= 45 { return "battery.50" }
        if level >= 20 { return "battery.25" }
        return "battery.0"
    }
}

struct MenuSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(uiFont(12, weight: .semibold))
            .foregroundColor(.labelSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct MenuRowButton: View {
    let title: String
    var systemImage: String? = nil
    var trailing: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.labelPrimary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                Text(title)
                    .font(uiFont(13, weight: .regular))
                    .foregroundColor(.labelPrimary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(uiFont(13, weight: .regular))
                        .foregroundColor(.labelSecondary)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum FathomStatusCopy {
    static func powerSourceLine(power: PowerStore) -> String {
        if !power.batteryPresent { return "Power Adapter" }
        if power.isCharging { return "Power Adapter" }
        if power.isOnAC { return "Power Adapter" }
        return "Battery"
    }

    static func onBatteryLine(power: PowerStore) -> String {
        if !power.batteryPresent { return "Desktop · AC only" }
        if power.isCharging {
            return "Charging · package \(String(format: "%.1f W", power.packageWatts))"
        }
        if power.isOnAC {
            if power.levelPercent >= 100 {
                return "Fully Charged · package \(String(format: "%.1f W", power.packageWatts))"
            }
            return "On Adapter · package \(String(format: "%.1f W", power.packageWatts))"
        }
        return "On Battery · package \(String(format: "%.1f W", power.packageWatts))"
    }

    static func timeDetail(power: PowerStore) -> String {
        if !power.batteryPresent { return "AC power" }
        if power.isCharging { return power.timeText }
        if power.isOnAC {
            return power.levelPercent >= 100 ? "Fully Charged" : power.statusText
        }
        return power.timeText
    }

    static func topAppLine(energy: ProcessEnergyStore) -> String {
        guard let top = energy.top.first else { return "None" }
        let label = BatteryMenuChrome.energyLabel(cpuPercent: top.cpuPercent)
        return "\(top.name) · \(label)"
    }

    static func energyModeLine(lowPower: Bool) -> String {
        lowPower ? "Low Power On" : "Low Power Off"
    }
}

struct StatusKVRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.42))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.92))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, 13)
    }
}

struct MainRoot: View {
    @ObservedObject private var power = PowerStore.shared
    @ObservedObject private var energy = ProcessEnergyStore.shared
    @State private var why = DrainLog.shared.whyLastHour()
    @State private var showMore = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: BatteryMenuChrome.batterySymbol(
                    level: power.levelPercent,
                    charging: power.isCharging,
                    onAC: power.isOnAC,
                    present: power.batteryPresent
                ))
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(.labelPrimary)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 48, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(power.batteryPresent ? "\(power.levelPercent)%" : "AC")
                        .font(uiFont(30, weight: .semibold))
                        .foregroundColor(.labelPrimary)
                        .monospacedDigit()
                    Text(FathomStatusCopy.timeDetail(power: power))
                        .font(uiFont(12, weight: .regular))
                        .foregroundColor(.labelSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if power.packageWatts > 0.05 || power.chargeWatts > 0.05 {
                HStack(spacing: 14) {
                    wattsChip(title: "Package", value: power.packageWatts)
                    if power.isCharging {
                        wattsChip(title: "Charge", value: power.chargeWatts)
                    } else if power.chargeWatts > 0.05 && !power.isOnAC {
                        wattsChip(title: "Draw", value: power.chargeWatts)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if power.wattHistorySpark.filter({ $0 > 0.01 }).count >= 3 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(sparklineWindowLabel)
                            .font(uiFont(10, weight: .medium))
                            .foregroundColor(.labelTertiary)
                        Spacer()
                        Text(String(format: "%.1f W", power.packageWatts))
                            .font(uiFont(10, weight: .medium))
                            .foregroundColor(.labelSecondary)
                            .monospacedDigit()
                    }
                    Sparkline(values: power.wattHistorySpark, color: .labelPrimary)
                        .frame(height: 34)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            MenuHairline().padding(.horizontal, 14)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MenuSectionHeader(title: "Power Source")
                        .padding(.horizontal, 16)
                    Text(FathomStatusCopy.powerSourceLine(power: power))
                        .font(uiFont(13, weight: .regular))
                        .foregroundColor(.labelPrimary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)

                    MenuHairline().padding(.horizontal, 14)

                    MenuSectionHeader(title: "Energy Mode")
                        .padding(.horizontal, 16)
                    Button {
                        BatteryMenuChrome.openBatterySettings()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: lowPower ? "leaf.fill" : "leaf")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.labelPrimary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Low Power Mode")
                                    .font(uiFont(13, weight: .regular))
                                    .foregroundColor(.labelPrimary)
                                Text("Open Battery Settings…")
                                    .font(uiFont(10, weight: .regular))
                                    .foregroundColor(.labelTertiary)
                            }
                            Spacer()
                            Text(lowPower ? "On" : "Off")
                                .font(uiFont(13, weight: .regular))
                                .foregroundColor(.labelSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.labelTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                    }

                    MenuHairline().padding(.horizontal, 14)

                    MenuSectionHeader(title: "Apps Using Energy")
                        .padding(.horizontal, 16)
                    if energy.top.isEmpty {
                        Text("No Apps Using Significant Energy")
                            .font(uiFont(13, weight: .regular))
                            .foregroundColor(.labelSecondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                    } else {
                        ForEach(energy.top.prefix(5)) { p in
                            HStack(spacing: 10) {
                                Text(p.name)
                                    .font(uiFont(13, weight: .regular))
                                    .foregroundColor(.labelPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(BatteryMenuChrome.energyLabel(cpuPercent: p.cpuPercent))
                                    .font(uiFont(12, weight: .regular))
                                    .foregroundColor(.labelSecondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        .padding(.bottom, 8)
                    }

                    MenuHairline().padding(.horizontal, 14)

                    MenuRowButton(title: "Open Dashboard", systemImage: "rectangle.portrait") {
                        NotificationCenter.default.post(name: .fathomOpenDashboard, object: nil)
                    }
                    .padding(.horizontal, 16)

                    MenuRowButton(title: "Battery Settings…", systemImage: "gearshape") {
                        BatteryMenuChrome.openBatterySettings()
                    }
                    .padding(.horizontal, 16)

                    MenuRowButton(title: showMore ? "Hide Options" : "More Options…") {
                        withAnimation(.easeInOut(duration: 0.15)) { showMore.toggle() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, showMore ? 0 : 6)

                    if showMore {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Menu bar label")
                                .font(uiFont(11, weight: .medium))
                                .foregroundColor(.labelTertiary)
                            Picker("", selection: Binding(
                                get: { MenuBarDisplayMode.current },
                                set: { MenuBarDisplayMode.set($0) }
                            )) {
                                Text("%").tag(MenuBarDisplayMode.percent)
                                Text("W").tag(MenuBarDisplayMode.watts)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Toggle(isOn: Binding(
                                get: { SystemBatteryMenuHider.isEnabled },
                                set: { SystemBatteryMenuHider.isEnabled = $0 }
                            )) {
                                Text("Replace system Battery icon")
                                    .font(uiFont(12, weight: .regular))
                                    .foregroundColor(.labelPrimary)
                            }
                            .toggleStyle(.switch)
                            .tint(Color.white.opacity(0.55))

                            Toggle(isOn: Binding(
                                get: { DrainAlertMonitor.isEnabled },
                                set: { DrainAlertMonitor.isEnabled = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Drain alerts")
                                        .font(uiFont(12, weight: .regular))
                                        .foregroundColor(.labelPrimary)
                                    Text("Notify if battery drops \(DrainAlertMonitor.dropPercent)%+ in \(DrainAlertMonitor.windowMinutes) min (local only).")
                                        .font(uiFont(10, weight: .regular))
                                        .foregroundColor(.labelTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                            .tint(Color.white.opacity(0.55))

                            Text("⌘-drag the menu bar icon to move it. Double-click opens Dashboard.")
                                .font(uiFont(11))
                                .foregroundColor(.labelTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            Slider(value: Binding(
                                get: { MenuBarPositionStore.normalized },
                                set: { MenuBarPositionStore.normalized = $0 }
                            ), in: 0...1)
                            .tint(Color.white.opacity(0.55))

                            MenuRowButton(
                                title: RNitroLink.isInstalled ? "Open MacBar" : "Get rNitro…",
                                systemImage: "gauge.with.dots.needle.67percent"
                            ) {
                                RNitroLink.openOrInstall()
                            }

                            HStack(spacing: 8) {
                                MinimalButton(title: "Updates") { UpdateChecker.checkManually() }
                                MinimalButton(title: "Website") { NSWorkspace.shared.open(UPDATE_PAGE_URL) }
                            }
                            Text(UpdateChecker.displayLabel(FATHOM_VERSION))
                                .font(uiFont(11))
                                .foregroundColor(.labelTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 6)
            }

            MenuHairline()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Why drain?")
                        .font(uiFont(12, weight: .semibold))
                        .foregroundColor(.labelSecondary)
                    Spacer()
                    Button {
                        why = DrainLog.shared.whyLastHour()
                    } label: {
                        Text("Refresh")
                            .font(uiFont(11, weight: .medium))
                            .foregroundColor(.labelTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Text(why.summary)
                    .font(uiFont(12, weight: .regular))
                    .foregroundColor(.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                if why.dropPercent > 0 {
                    Text("~\(why.dropPercent)% · \(why.windowLabel)")
                        .font(uiFont(11, weight: .regular))
                        .foregroundColor(.labelSecondary)
                }
                ForEach(Array(why.culprits.prefix(2).enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.name)
                            .font(uiFont(11, weight: .regular))
                            .foregroundColor(.labelSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(c.note)
                            .font(uiFont(11, weight: .regular))
                            .foregroundColor(.labelTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .background(Color.white.opacity(0.03))
        }
        .frame(width: 292, height: 480)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear {
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            why = DrainLog.shared.whyLastHour()
        }
    }

    private var sparklineWindowLabel: String {
        let secs = power.wattHistory.count * 2
        if secs >= 50 * 60 { return "Package · last hour" }
        if secs >= 60 {
            let m = max(1, secs / 60)
            return "Package · last \(m) min"
        }
        return "Package · last samples"
    }

    private func wattsChip(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(uiFont(9, weight: .semibold))
                .foregroundColor(.labelTertiary)
                .tracking(0.6)
            Text(String(format: "%.1f W", value))
                .font(uiFont(13, weight: .semibold))
                .foregroundColor(.labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

final class DashboardPrefs: ObservableObject {
    static let shared = DashboardPrefs()

    @Published var showFauxMenubar = true
    @Published var showFathomPill = true
    @Published var showPackageLine = true
    @Published var largePercent = true
    @Published var showPowerSource = true
    @Published var showEnergyMode = true
    @Published var showAppsRow = true
    @Published var showWhyRow = true
    @Published var showSparkline = false
    @Published var showTopAppsList = false
    @Published var showWhyDetail = false
    @Published var showHealth = false
    @Published var showTimeRemaining = false
    @Published var density: Density = .comfortable
    @Published var width: CardWidth = .regular
    @Published var cornerRadius: Double = 18

    enum Density: String, CaseIterable, Identifiable {
        case compact, comfortable, roomy
        var id: String { rawValue }
        var label: String {
            switch self {
            case .compact: return "Compact"
            case .comfortable: return "Comfortable"
            case .roomy: return "Roomy"
            }
        }
        var rowPad: CGFloat {
            switch self {
            case .compact: return 8
            case .comfortable: return 13
            case .roomy: return 17
            }
        }
        var hPad: CGFloat {
            switch self {
            case .compact: return 20
            case .comfortable: return 28
            case .roomy: return 32
            }
        }
        var heroSize: CGFloat {
            switch self {
            case .compact: return 42
            case .comfortable: return 56
            case .roomy: return 64
            }
        }
    }

    enum CardWidth: String, CaseIterable, Identifiable {
        case narrow, regular, wide
        var id: String { rawValue }
        var label: String {
            switch self {
            case .narrow: return "Narrow"
            case .regular: return "Regular"
            case .wide: return "Wide"
            }
        }
        var points: CGFloat {
            switch self {
            case .narrow: return 360
            case .regular: return 440
            case .wide: return 520
            }
        }
    }

    private init() { load() }

    func load() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool {
            if d.object(forKey: kDashboardPrefs + "." + k) == nil { return def }
            return d.bool(forKey: kDashboardPrefs + "." + k)
        }
        showFauxMenubar = b("fauxMenubar", true)
        showFathomPill = b("pill", true)
        showPackageLine = b("packageLine", true)
        largePercent = b("largePercent", true)
        showPowerSource = b("powerSource", true)
        showEnergyMode = b("energyMode", true)
        showAppsRow = b("appsRow", true)
        showWhyRow = b("whyRow", true)
        showSparkline = b("sparkline", false)
        showTopAppsList = b("topApps", false)
        showWhyDetail = b("whyDetail", false)
        showHealth = b("health", false)
        showTimeRemaining = b("timeRemaining", false)
        if let s = d.string(forKey: kDashboardPrefs + ".density"),
           let v = Density(rawValue: s) { density = v }
        if let s = d.string(forKey: kDashboardPrefs + ".width"),
           let v = CardWidth(rawValue: s) { width = v }
        let cr = d.double(forKey: kDashboardPrefs + ".corner")
        if cr >= 8 { cornerRadius = cr } else { cornerRadius = 18 }
    }

    func save() {
        let d = UserDefaults.standard
        func setB(_ k: String, _ v: Bool) { d.set(v, forKey: kDashboardPrefs + "." + k) }
        setB("fauxMenubar", showFauxMenubar)
        setB("pill", showFathomPill)
        setB("packageLine", showPackageLine)
        setB("largePercent", largePercent)
        setB("powerSource", showPowerSource)
        setB("energyMode", showEnergyMode)
        setB("appsRow", showAppsRow)
        setB("whyRow", showWhyRow)
        setB("sparkline", showSparkline)
        setB("topApps", showTopAppsList)
        setB("whyDetail", showWhyDetail)
        setB("health", showHealth)
        setB("timeRemaining", showTimeRemaining)
        d.set(density.rawValue, forKey: kDashboardPrefs + ".density")
        d.set(width.rawValue, forKey: kDashboardPrefs + ".width")
        d.set(cornerRadius, forKey: kDashboardPrefs + ".corner")
        NotificationCenter.default.post(name: .fathomDashboardPrefsChanged, object: nil)
    }

    func resetToMockDefaults() {
        showFauxMenubar = true
        showFathomPill = true
        showPackageLine = true
        largePercent = true
        showPowerSource = true
        showEnergyMode = true
        showAppsRow = true
        showWhyRow = true
        showSparkline = false
        showTopAppsList = false
        showWhyDetail = false
        showHealth = false
        showTimeRemaining = false
        density = .comfortable
        width = .regular
        cornerRadius = 18
        save()
    }

    func applyPreset(_ name: String) {
        switch name {
        case "minimal":
            showFauxMenubar = false
            showFathomPill = false
            showPackageLine = true
            largePercent = true
            showPowerSource = false
            showEnergyMode = false
            showAppsRow = false
            showWhyRow = true
            showSparkline = false
            showTopAppsList = false
            showWhyDetail = false
            showHealth = false
            showTimeRemaining = true
            density = .compact
            width = .narrow
        case "full":
            showFauxMenubar = true
            showFathomPill = true
            showPackageLine = true
            largePercent = true
            showPowerSource = true
            showEnergyMode = true
            showAppsRow = true
            showWhyRow = true
            showSparkline = true
            showTopAppsList = true
            showWhyDetail = true
            showHealth = true
            showTimeRemaining = true
            density = .roomy
            width = .wide
        default:
            resetToMockDefaults()
            return
        }
        save()
    }
}

struct DashboardCustomizePanel: View {
    @ObservedObject var prefs: DashboardPrefs
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Customize Dashboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.92))
                Spacer()
                Button("Done", action: onDone)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.7))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    presetRow
                    sectionTitle("Chrome")
                    toggle("Faux menubar strip", $prefs.showFauxMenubar)
                    toggle("FATHOM pill", $prefs.showFathomPill)
                    toggle("Package subtitle", $prefs.showPackageLine)
                    toggle("Large percent", $prefs.largePercent)

                    sectionTitle("Rows")
                    toggle("Power Source", $prefs.showPowerSource)
                    toggle("Energy Mode", $prefs.showEnergyMode)
                    toggle("Apps Using Energy", $prefs.showAppsRow)
                    toggle("Why drain?", $prefs.showWhyRow)
                    toggle("Time remaining", $prefs.showTimeRemaining)

                    sectionTitle("Modules")
                    toggle("Package sparkline", $prefs.showSparkline)
                    toggle("Top apps list", $prefs.showTopAppsList)
                    toggle("Why-drain detail", $prefs.showWhyDetail)
                    toggle("Health & cycles", $prefs.showHealth)

                    sectionTitle("Layout")
                    labeledPicker("Density", selection: $prefs.density) {
                        ForEach(DashboardPrefs.Density.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    labeledPicker("Width", selection: $prefs.width) {
                        ForEach(DashboardPrefs.CardWidth.allCases) { w in
                            Text(w.label).tag(w)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Corner radius \(Int(prefs.cornerRadius))")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.55))
                        Slider(value: $prefs.cornerRadius, in: 8...28, step: 1)
                            .tint(Color.white.opacity(0.5))
                    }

                    Button {
                        prefs.resetToMockDefaults()
                    } label: {
                        Text("Reset to default card")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .frame(width: 280)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .onChange(of: prefs.showFauxMenubar) { _, _ in prefs.save() }
        .onChange(of: prefs.showFathomPill) { _, _ in prefs.save() }
        .onChange(of: prefs.showPackageLine) { _, _ in prefs.save() }
        .onChange(of: prefs.largePercent) { _, _ in prefs.save() }
        .onChange(of: prefs.showPowerSource) { _, _ in prefs.save() }
        .onChange(of: prefs.showEnergyMode) { _, _ in prefs.save() }
        .onChange(of: prefs.showAppsRow) { _, _ in prefs.save() }
        .onChange(of: prefs.showWhyRow) { _, _ in prefs.save() }
        .onChange(of: prefs.showSparkline) { _, _ in prefs.save() }
        .onChange(of: prefs.showTopAppsList) { _, _ in prefs.save() }
        .onChange(of: prefs.showWhyDetail) { _, _ in prefs.save() }
        .onChange(of: prefs.showHealth) { _, _ in prefs.save() }
        .onChange(of: prefs.showTimeRemaining) { _, _ in prefs.save() }
        .onChange(of: prefs.density) { _, _ in prefs.save() }
        .onChange(of: prefs.width) { _, _ in prefs.save() }
        .onChange(of: prefs.cornerRadius) { _, _ in prefs.save() }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            presetButton("Mock") { prefs.applyPreset("mock") }
            presetButton("Minimal") { prefs.applyPreset("minimal") }
            presetButton("Full") { prefs.applyPreset("full") }
        }
    }

    private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(Color.white.opacity(0.38))
            .padding(.top, 4)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(Color.white.opacity(0.88))
        }
        .toggleStyle(.switch)
        .tint(Color.white.opacity(0.55))
    }

    private func labeledPicker<V: Hashable, Content: View>(
        _ title: String,
        selection: Binding<V>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.55))
            Picker("", selection: selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
        }
    }
}

struct DashboardRoot: View {
    @ObservedObject private var power = PowerStore.shared
    @ObservedObject private var energy = ProcessEnergyStore.shared
    @ObservedObject private var prefs = DashboardPrefs.shared
    @State private var why = DrainLog.shared.whyLastHour()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var clock = Date()
    @State private var showCustomize = false

    private var topApp: String { FathomStatusCopy.topAppLine(energy: energy) }
    private var hPad: CGFloat { prefs.density.hPad }
    private var rowPad: CGFloat { prefs.density.rowPad }

    private var packageSubtitle: String {
        if !power.batteryPresent {
            return String(format: "Desktop · package %.1f W", power.packageWatts)
        }
        if power.isCharging {
            return String(format: "Charging · package %.1f W", power.packageWatts)
        }
        if power.isOnAC {
            if power.levelPercent >= 100 {
                return String(format: "Fully Charged · package %.1f W", power.packageWatts)
            }
            return String(format: "On Adapter · package %.1f W", power.packageWatts)
        }
        return String(format: "On Battery · package %.1f W", power.packageWatts)
    }

    private var clockText: String {
        let f = DateFormatter()
        f.dateFormat = "E HH:mm"
        return f.string(from: clock)
    }

    private var whyValue: String {
        if why.dropPercent > 0 { return "−\(why.dropPercent)% · \(why.windowLabel.isEmpty ? "last hour" : why.windowLabel)" }
        if !why.windowLabel.isEmpty { return why.windowLabel }
        return "Last hour"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cardBody
            if showCustomize {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.5)
                DashboardCustomizePanel(prefs: prefs) {
                    withAnimation(.easeInOut(duration: 0.15)) { showCustomize = false }
                }
            }
        }
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .onAppear {
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            why = DrainLog.shared.whyLastHour()
            clock = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now in
            clock = now
            why = DrainLog.shared.whyLastHour()
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if prefs.showFauxMenubar {
                    Spacer(minLength: 0)
                    Text("Wi‑Fi")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.72))
                    HStack(spacing: 4) {
                        Image(systemName: BatteryMenuChrome.batterySymbol(
                            level: power.levelPercent,
                            charging: power.isCharging,
                            onAC: power.isOnAC,
                            present: power.batteryPresent
                        ))
                        .font(.system(size: 12, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        Text(power.batteryPresent ? "\(power.levelPercent)%" : "AC")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    .foregroundColor(Color.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    Text(clockText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Color.white.opacity(0.72))
                } else {
                    Text("Dashboard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.4))
                    Spacer(minLength: 0)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showCustomize.toggle() }
                } label: {
                    Image(systemName: showCustomize ? "slider.horizontal.3" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(showCustomize ? 0.95 : 0.45))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(Color.white.opacity(showCustomize ? 0.12 : 0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Customize dashboard layout")
            }
            .padding(.horizontal, hPad - 4)
            .padding(.top, 12)
            .padding(.bottom, prefs.showFauxMenubar ? 8 : 4)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: prefs.density == .compact ? 4 : 8) {
                    if prefs.largePercent {
                        Text(power.batteryPresent ? "\(power.levelPercent)%" : "AC")
                            .font(.system(size: prefs.density.heroSize, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.96))
                            .monospacedDigit()
                            .tracking(-1.5)
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: BatteryMenuChrome.batterySymbol(
                                level: power.levelPercent,
                                charging: power.isCharging,
                                onAC: power.isOnAC,
                                present: power.batteryPresent
                            ))
                            .font(.system(size: 28, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            Text(power.batteryPresent ? "\(power.levelPercent)%" : "AC")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                        .foregroundColor(Color.white.opacity(0.96))
                    }
                    if prefs.showPackageLine {
                        Text(packageSubtitle)
                            .font(.system(size: prefs.density == .compact ? 12 : 14, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.42))
                    }
                    if prefs.showTimeRemaining {
                        Text(FathomStatusCopy.timeDetail(power: power))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color.white.opacity(0.35))
                    }
                }
                Spacer(minLength: 8)
                if prefs.showFathomPill {
                    Text("FATHOM")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.4)
                        .foregroundColor(Color.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, hPad)
            .padding(.top, prefs.density == .compact ? 10 : 18)
            .padding(.bottom, prefs.density == .compact ? 14 : 22)

            if hasAnyRow {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, hPad)

                VStack(spacing: 0) {
                    if prefs.showPowerSource {
                        dashRow("Power Source", FathomStatusCopy.powerSourceLine(power: power))
                    }
                    if prefs.showEnergyMode {
                        dashRow("Energy Mode", FathomStatusCopy.energyModeLine(lowPower: lowPower))
                    }
                    if prefs.showAppsRow {
                        dashRow("Apps Using Energy", topApp)
                    }
                    if prefs.showWhyRow {
                        dashRow("Why drain?", whyValue)
                    }
                    if prefs.showHealth {
                        let health: String = {
                            var p: [String] = []
                            if let h = power.healthPercent { p.append("\(h)%") }
                            if let c = power.cycleCount { p.append("\(c) cycles") }
                            return p.isEmpty ? "—" : p.joined(separator: " · ")
                        }()
                        dashRow("Health", health)
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.top, 6)
                .padding(.bottom, prefs.hasExtraModules ? 8 : 20)
            }

            if prefs.showSparkline, power.wattHistorySpark.filter({ $0 > 0.01 }).count >= 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Package power")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.4))
                    Sparkline(values: power.wattHistorySpark, color: .white)
                        .frame(height: 36)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 12)
            }

            if prefs.showTopAppsList {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apps Using Energy")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.4))
                    if energy.top.isEmpty {
                        Text("No apps using significant energy")
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.35))
                    } else {
                        ForEach(energy.top.prefix(6)) { p in
                            HStack {
                                Text(p.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(Color.white.opacity(0.9))
                                    .lineLimit(1)
                                Spacer()
                                Text(BatteryMenuChrome.energyLabel(cpuPercent: p.cpuPercent))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.white.opacity(0.45))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, 12)
            }

            if prefs.showWhyDetail {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Why drain?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.4))
                        Spacer()
                        Button("Refresh") { why = DrainLog.shared.whyLastHour() }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.45))
                            .buttonStyle(.plain)
                    }
                    Text(why.summary)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(why.culprits.prefix(4).enumerated()), id: \.offset) { _, c in
                        HStack {
                            Text(c.name)
                                .font(.system(size: 12))
                                .foregroundColor(Color.white.opacity(0.85))
                                .lineLimit(1)
                            Spacer()
                            Text(c.note)
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .padding(.horizontal, hPad)
                .padding(.bottom, 16)
            }

            if !prefs.hasExtraModules && hasAnyRow == false {
                Spacer().frame(height: 12)
            }
        }
        .frame(width: prefs.width.points)
        .background(
            RoundedRectangle(cornerRadius: prefs.cornerRadius, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: prefs.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: prefs.cornerRadius, style: .continuous))
    }

    private var hasAnyRow: Bool {
        prefs.showPowerSource || prefs.showEnergyMode || prefs.showAppsRow
            || prefs.showWhyRow || prefs.showHealth
    }

    private func dashRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: prefs.density == .compact ? 13.5 : 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.42))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: prefs.density == .compact ? 13.5 : 15, weight: .regular))
                .foregroundColor(Color.white.opacity(0.92))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, rowPad)
    }
}

private extension DashboardPrefs {
    var hasExtraModules: Bool {
        showSparkline || showTopAppsList || showWhyDetail
    }
}

enum MenuBarBatteryIcon {
    static func image(
        level: Int,
        charging: Bool,
        onAC: Bool,
        present: Bool,
        packageWatts: Double = 0,
        mode: MenuBarDisplayMode = .current
    ) -> NSImage? {
        let label: String = {
            if mode == .watts {
                if packageWatts >= 10 {
                    return String(format: "%.0fW", packageWatts)
                }
                return String(format: "%.1fW", packageWatts)
            }
            if !present { return "AC" }
            return "\(level)%"
        }()
        let name = BatteryMenuChrome.batterySymbol(
            level: level, charging: charging, onAC: onAC, present: present
        )
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        guard let symbolRaw = NSImage(systemSymbolName: name, accessibilityDescription: "Battery")?
            .withSymbolConfiguration(config) else {
            return textOnlyImage(label)
        }
        let symbol = symbolRaw
        symbol.isTemplate = true

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])

        let gap: CGFloat = 4
        let padX: CGFloat = 2
        let symW = min(max(symbol.size.width, 18), 28)
        let symH = min(max(symbol.size.height, 10), 14)
        let canvasH: CGFloat = 16
        let canvasW = (padX + symW + gap + textSize.width + padX + 1).rounded(.up)

        let img = NSImage(size: NSSize(width: canvasW, height: canvasH), flipped: false) { rect in
            let sy = ((rect.height - symH) / 2).rounded(.down)
            let sRect = NSRect(x: padX, y: sy, width: symW, height: symH)
            symbol.draw(in: sRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            NSColor.black.set()
            sRect.fill(using: .sourceIn)

            let tx = padX + symW + gap
            let ty = ((rect.height - textSize.height) / 2 - 0.5).rounded(.down)
            (label as NSString).draw(
                at: NSPoint(x: tx, y: ty),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.black,
                ]
            )
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func textOnlyImage(_ label: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let canvasW = (textSize.width + 8).rounded(.up)
        let img = NSImage(size: NSSize(width: canvasW, height: 16), flipped: false) { _ in
            (label as NSString).draw(
                at: NSPoint(x: 4, y: 1),
                withAttributes: [.font: font, .foregroundColor: NSColor.black]
            )
            return true
        }
        img.isTemplate = true
        return img
    }

    static func title(level: Int, present: Bool, onAC: Bool, charging: Bool) -> String {
        _ = (level, present, onAC, charging)
        return ""
    }

    static func preferredLength(title: String, image: NSImage?) -> CGFloat {
        _ = title
        let w = (image?.size.width ?? 40) + 8
        return min(max(w.rounded(.up), 36), 110)
    }
}

struct VersionInfo: Decodable {
    let latest: String
    let beta: String?
    let experimental: String?
}

private struct VersionManifest: Decodable {
    let latest: String
    let beta: String?
    let experimental: String?
    let releases: ReleaseMap?
    struct ReleaseMap: Decodable {
        let stable: Channel?
        let beta: Channel?
        let experimental: Channel?
    }
    struct Channel: Decodable {
        let zip: String?
    }
    func zipName(for versionId: String) -> String {
        if let z = releases?.beta?.zip, versionId == beta || versionId == latest { return z }
        if let z = releases?.stable?.zip, versionId == latest { return z }
        if let z = releases?.experimental?.zip, versionId == experimental { return z }
        if let z = releases?.beta?.zip { return z }
        return "Fathom-\(versionId).zip"
    }
}

enum UpdateChecker {
    static func versionNumbers(_ v: String) -> [Int] {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        var nums: [Int] = [], cur = ""
        for ch in s {
            if ch.isNumber { cur.append(ch) }
            else if !cur.isEmpty {
                if let n = Int(cur) { nums.append(n) }
                cur = ""
            }
        }
        if !cur.isEmpty, let n = Int(cur) { nums.append(n) }
        return nums
    }
    private static func channelRank(_ id: String) -> Int {
        let s = id.lowercased()
        if s.contains("experimental") { return 3 }
        if s.contains("beta") { return 2 }
        if s.contains("final") || s.contains("stable") { return 1 }
        return 0
    }
    static func isNewer(_ remote: String, than current: String) -> Bool {
        if remote == current { return false }
        let rn = versionNumbers(remote), cn = versionNumbers(current)
        let count = max(rn.count, cn.count)
        for i in 0..<count {
            let r = i < rn.count ? rn[i] : 0
            let c = i < cn.count ? cn[i] : 0
            if r != c { return r > c }
        }
        let rr = channelRank(remote), cr = channelRank(current)
        if rr != cr { return rr > cr }
        return remote.localizedCaseInsensitiveCompare(current) == .orderedDescending
    }
    static func displayLabel(_ versionId: String) -> String {
        versionId
            .replacingOccurrences(of: "-Experimental", with: " Experimental")
            .replacingOccurrences(of: "-Beta", with: " Beta")
            .replacingOccurrences(of: "-Final", with: " Final")
    }
    private static func fetchVersionInfo(completion: @escaping (VersionInfo?) -> Void) {
        var req = URLRequest(url: UPDATE_CHECK_URL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let info = try? JSONDecoder().decode(VersionInfo.self, from: data) {
                completion(info)
            } else {
                completion(nil)
            }
        }.resume()
    }
    static func checkOnLaunch() {
        checkPendingUpdateResult()
        fetchVersionInfo { info in
            guard let info else { return }
            evaluateRemoteVersions(info, manual: false)
        }
    }
    private static func checkPendingUpdateResult() {
        let resultURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Fathom/update-result.txt")
        guard let raw = try? String(contentsOf: resultURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: resultURL)
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let status = parts.first.map(String.init) ?? ""
        if status == "ok" { return }
        let detail = parts.count > 1 ? String(parts[1]) : "The update helper did not finish successfully."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let alert = NSAlert()
            alert.messageText = "Previous Update Did Not Complete"
            alert.informativeText = detail + "\n\nCheck ~/Library/Logs/Fathom/update.log or reinstall from chopstickshq.com/fathom."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Website")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(UPDATE_PAGE_URL)
            }
        }
    }
    static func checkManually() {
        fetchVersionInfo { info in
            DispatchQueue.main.async {
                guard let info else {
                    let alert = NSAlert()
                    alert.messageText = "Could Not Check for Updates"
                    alert.informativeText = "Could not reach chopstickshq.com. Check your internet connection and try again."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                evaluateRemoteVersions(info, manual: true)
            }
        }
    }
    static func installPathLabel() -> String {
        let path = Bundle.main.bundlePath
        if path.contains("AppTranslocation") { return "Downloads (translocated)" }
        if UpdateInstaller.isSystemApplicationsBundle(path) { return "/Applications" }
        if path.contains("/Applications/") { return path }
        return path
    }
    private static func evaluateRemoteVersions(_ info: VersionInfo, manual: Bool) {
        let preferred = info.beta ?? info.latest
        let newer = isNewer(preferred, than: FATHOM_VERSION)
        let onMain = {
            if !newer {
                if manual {
                    let alert = NSAlert()
                    alert.messageText = "You're Up to Date"
                    alert.informativeText = "Fathom \(displayLabel(FATHOM_VERSION)) is the newest build available."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
                return
            }
            presentUpdate(remote: preferred)
        }
        if manual { onMain() }
        else if newer { DispatchQueue.main.async(execute: onMain) }
    }
    private static func presentUpdate(remote: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Fathom Update Available"
        alert.informativeText = "You're running \(displayLabel(FATHOM_VERSION)).\n\n\(displayLabel(remote)) is available.\n\nDownload and install now? Fathom will restart when done."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            UpdateInstaller.install(remoteVersion: remote)
        }
    }
}

enum UpdateInstaller {
    private static var progressPanel: NSPanel?
    private static var progressBar: NSProgressIndicator?
    private static var progressDetail: NSTextField?
    private static var downloadProgressObservation: NSKeyValueObservation?
    private static let updateLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fathom/update.log")
    private static let updateResultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fathom/update-result.txt")

    static func isSystemApplicationsBundle(_ path: String) -> Bool {
        if path.hasPrefix("/Applications/") { return true }
        if path.contains("/System/Volumes/Data/Applications/") { return true }
        return false
    }
    private static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let dir = updateLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: updateLogURL.path),
           let h = try? FileHandle(forWritingTo: updateLogURL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.write(to: updateLogURL, atomically: true, encoding: .utf8)
        }
    }
    static func zipURL(for zipName: String) -> URL {
        URL(string: "\(UPDATE_CDN_BASE)/\(zipName)")!
    }
    private static func fetchManifest() -> VersionManifest? {
        let sem = DispatchSemaphore(value: 0)
        var manifest: VersionManifest?
        var req = URLRequest(url: UPDATE_CHECK_URL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { manifest = try? JSONDecoder().decode(VersionManifest.self, from: data) }
            sem.signal()
        }.resume()
        sem.wait()
        return manifest
    }
    static func install(remoteVersion: String) {
        log("Update requested for \(remoteVersion) from \(FATHOM_VERSION)")
        DispatchQueue.main.async { showDownloadProgress(for: remoteVersion) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performInstall(remoteVersion: remoteVersion)
            DispatchQueue.main.async {
                hideDownloadProgress()
                if case .failure(let msg) = result {
                    let alert = NSAlert()
                    alert.messageText = "Update Failed"
                    alert.informativeText = msg
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Open Website")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(UPDATE_PAGE_URL)
                    }
                }
            }
        }
    }
    private static func showDownloadProgress(for version: String) {
        hideDownloadProgress()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Fathom Update"
        panel.isFloatingPanel = true
        panel.level = .floating
        let stack = NSStackView(frame: NSRect(x: 16, y: 16, width: 328, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let label = NSTextField(labelWithString: "Downloading update…")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: "Fetching \(version) from chopstickshq.com")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.controlSize = .regular
        bar.frame = NSRect(x: 0, y: 0, width: 328, height: 8)
        bar.startAnimation(nil)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(bar)
        panel.contentView = stack
        panel.center()
        panel.orderFrontRegardless()
        progressPanel = panel
        progressBar = bar
        progressDetail = detail
    }
    private static func hideDownloadProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
        progressBar = nil
        progressDetail = nil
    }
    private static func updateDownloadProgress(received: Int, expected: Int, version: String) {
        DispatchQueue.main.async {
            guard let bar = progressBar else { return }
            if expected > 0 {
                bar.isIndeterminate = false
                bar.maxValue = Double(expected)
                bar.doubleValue = Double(received)
                let pct = min(100, Int((Double(received) / Double(expected)) * 100))
                progressDetail?.stringValue = "\(pct)% · \(formatBytes(received)) of \(formatBytes(expected))"
            } else {
                progressDetail?.stringValue = "\(formatBytes(received)) downloaded · \(version)"
            }
        }
    }
    private static func formatBytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return "\(n) B"
    }
    private enum InstallResult { case success; case failure(String) }

    private static func performInstall(remoteVersion: String) -> InstallResult {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let manifest = fetchManifest()
        let zipName = manifest?.zipName(for: remoteVersion) ?? "Fathom-\(remoteVersion).zip"
        let zipFile = tmp.appendingPathComponent(zipName)
        let extractDir = tmp.appendingPathComponent("Fathom-update-extract", isDirectory: true)
        try? fm.removeItem(at: zipFile)
        try? fm.removeItem(at: extractDir)
        log("Resolved zip: \(zipName)")

        let sem = DispatchSemaphore(value: 0)
        var dlError: Error?
        var httpStatus = 0
        var req = URLRequest(url: zipURL(for: zipName))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 180
        let task = URLSession.shared.downloadTask(with: req) { tempURL, resp, error in
            dlError = error
            if let http = resp as? HTTPURLResponse { httpStatus = http.statusCode }
            guard error == nil, let tempURL else { sem.signal(); return }
            do {
                if fm.fileExists(atPath: zipFile.path) { try fm.removeItem(at: zipFile) }
                try fm.moveItem(at: tempURL, to: zipFile)
            } catch { dlError = error }
            sem.signal()
        }
        downloadProgressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            updateDownloadProgress(received: Int(progress.completedUnitCount),
                                   expected: Int(progress.totalUnitCount), version: remoteVersion)
        }
        task.resume()
        sem.wait()
        downloadProgressObservation = nil

        if let dlError {
            return .failure("Could not download \(zipName): \(dlError.localizedDescription)")
        }
        if httpStatus != 0 && httpStatus != 200 {
            return .failure("Server returned HTTP \(httpStatus) for \(zipName). Download manually from chopstickshq.com/fathom.")
        }
        guard fm.fileExists(atPath: zipFile.path) else {
            return .failure("Download did not save \(zipName).")
        }
        let size = (try? fm.attributesOfItem(atPath: zipFile.path)[.size] as? Int) ?? 0
        log("Downloaded \(zipName): \(size) bytes")
        let head = (try? Data(contentsOf: zipFile, options: [.mappedIfSafe]).prefix(64)) ?? Data()
        if head.count >= 2, head[0] == 0x3C {
            return .failure("Got HTML instead of App ZIP. File may be missing on the server.")
        }
        guard head.count >= 4, head[0] == 0x50, head[1] == 0x4B else {
            return .failure("Downloaded file is not a valid ZIP.")
        }
        if size < 40_000 {
            return .failure("Downloaded package is too small (\(size) bytes).")
        }
        DispatchQueue.main.async {
            progressDetail?.stringValue = "Installing \(remoteVersion)…"
            progressBar?.isIndeterminate = true
            progressBar?.startAnimation(nil)
        }
        if let extractError = extractApp(from: zipFile, to: extractDir) {
            return .failure("Could not extract \(zipName): \(extractError)")
        }
        guard let staged = findAppBundle(in: extractDir) else {
            return .failure("Fathom.app not found inside \(zipName).")
        }
        let dest = installDestination()
        log("Installing to \(dest.path)")
        let replace = replaceApp(stagedApp: staged, destination: dest)
        if let installError = replace.error {
            return .failure(installError)
        }
        if replace.opensBeforeQuit {
            try? "ok|\n".write(to: updateResultURL, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Installed"
            alert.informativeText = "Fathom will restart now to finish applying \(UpdateChecker.displayLabel(remoteVersion))."
            alert.alertStyle = .informational
            alert.runModal()
            if replace.opensBeforeQuit { NSWorkspace.shared.open(dest) }
            NSApp.terminate(nil)
        }
        return .success
    }
    private struct ReplaceResult { var error: String?; var opensBeforeQuit = false }
    private static func shellQuote(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
    private static func runCommand(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        guard (try? proc.run()) != nil else { return (-1, "Could not run \(launchPath)") }
        proc.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func extractApp(from zipURL: URL, to destDir: URL) -> String? {
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let ditto = runCommand("/usr/bin/ditto", ["-xk", zipURL.path, destDir.path])
        if ditto.0 == 0 { return nil }
        let unzip = runCommand("/usr/bin/unzip", ["-qo", zipURL.path, "-d", destDir.path])
        if unzip.0 == 0 { return nil }
        return [ditto.1, unzip.1].filter { !$0.isEmpty }.joined(separator: " | ")
    }
    private static func installDestination() -> URL {
        let current = URL(fileURLWithPath: Bundle.main.bundlePath)
        let homeApp = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Fathom.app", isDirectory: true)
        let path = current.path
        if path.contains("AppTranslocation") || path.hasPrefix("/Volumes/") { return homeApp }
        if isSystemApplicationsBundle(path) {
            return URL(fileURLWithPath: "/Applications/Fathom.app")
        }
        let parent = current.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) { return current }
        return homeApp
    }
    private static func findAppBundle(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let url as URL in e {
            var isDir: ObjCBool = false
            if url.lastPathComponent == "Fathom.app",
               FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return nil
    }
    private static func replaceApp(stagedApp: URL, destination: URL) -> ReplaceResult {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let cacheDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Fathom/update-staging", isDirectory: true)
        let durableStage = cacheDir.appendingPathComponent("Fathom.app", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: durableStage)
        let stageCopy = runCommand("/usr/bin/ditto", [stagedApp.path, durableStage.path])
        if stageCopy.0 != 0 {
            return ReplaceResult(error: stageCopy.1.isEmpty ? "Could not stage the update package." : stageCopy.1)
        }
        let adminDest = isSystemApplicationsBundle(destination.path)
            ? URL(fileURLWithPath: "/Applications/Fathom.app") : destination
        let staged = shellQuote(durableStage.path)
        let target = shellQuote(adminDest.path)
        let parentPath = shellQuote(adminDest.deletingLastPathComponent().path)
        let pid = ProcessInfo.processInfo.processIdentifier
        let logPath = shellQuote(updateLogURL.path)
        let resultPath = shellQuote(updateResultURL.path)

        if isSystemApplicationsBundle(destination.path) {
            let errPipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = [
                "-e",
                "do shell script \"mkdir -p /Applications && rm -rf '\(target)' && /usr/bin/ditto '\(staged)' '\(target)' && /usr/bin/xattr -cr '\(target)'\" with administrator privileges"
            ]
            proc.standardError = errPipe
            proc.standardOutput = Pipe()
            guard (try? proc.run()) != nil else {
                return ReplaceResult(error: "Could not request administrator access.")
            }
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                return ReplaceResult(error: "Could not replace Fathom in /Applications. Use ~/Applications or download from the website.")
            }
            return ReplaceResult(opensBeforeQuit: true)
        }

        let scriptURL = fm.temporaryDirectory.appendingPathComponent("fathom-apply-update.sh")
        let script = """
#!/bin/bash
LOG='\(logPath)'
RESULT='\(resultPath)'
write_result() { printf '%s|%s\\n' "$1" "$2" > "$RESULT"; }
trap 'code=$?; if [ ! -f "$RESULT" ] || [ ! -s "$RESULT" ]; then write_result fail "Update helper exited with code $code"; fi' EXIT
write_result pending "Update in progress…"
while kill -0 \(pid) 2>/dev/null; do sleep 0.25; done
sleep 0.5
mkdir -p '\(parentPath)' || { write_result fail "Could not create install folder"; exit 1; }
rm -rf '\(target)' || { write_result fail "Could not remove old Fathom.app"; exit 1; }
if ! /usr/bin/ditto '\(staged)' '\(target)' 2>>"$LOG"; then
  write_result fail "ditto failed"; exit 1
fi
xattr -cr '\(target)' 2>/dev/null || true
write_result ok ""
open '\(target)'
"""
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return ReplaceResult(error: "Could not prepare the update helper script.")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else {
            return ReplaceResult(error: "Could not launch the update helper.")
        }
        return ReplaceResult(opensBeforeQuit: false)
    }
}

enum MenuBarPositionStore {
    static var normalized: Double {
        get {
            if UserDefaults.standard.object(forKey: kMenuBarPosition) == nil { return 0.15 }
            return min(1, max(0, UserDefaults.standard.double(forKey: kMenuBarPosition)))
        }
        set {
            UserDefaults.standard.set(min(1, max(0, newValue)), forKey: kMenuBarPosition)
            applyPreferredPosition()
            NotificationCenter.default.post(name: .fathomRebuildStatusItem, object: nil)
        }
    }

    static var preferredScore: Double {
        80 + normalized * 420
    }

    static func applyPreferredPosition() {
        let score = preferredScore
        let keys = [
            "NSStatusItem Preferred Position \(kMenuBarAutosaveName)",
            "NSStatusItem Preferred Position Fathom",
            "NSStatusItem Preferred Position com.chopstickshq.fathom",
            "NSStatusItem Preferred Position Item-Fathom",
        ]
        for key in keys {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            p.arguments = ["-currentHost", "write", "com.apple.controlcenter", key, "-float", String(score)]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
        }
        UserDefaults.standard.set(score, forKey: "NSStatusItem Preferred Position")
        UserDefaults.standard.set(score, forKey: "NSStatusItem Preferred Position \(kMenuBarAutosaveName)")
    }

    static func configureStatusItem(_ item: NSStatusItem) {
        (item as NSObject).setValue(kMenuBarAutosaveName, forKey: "autosaveName")
        applyPreferredPosition()
    }
}

enum SystemBatteryMenuHider {
    private static let domain = "com.apple.controlcenter"
    private static let batteryKey = "Battery"
    private static let savedValueKey = "fathom.savedSystemBatteryMenuValue"
    private static let didHideKey = "fathom.didHideSystemBattery"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: kReplaceSystemBattery) == nil { return true }
            return UserDefaults.standard.bool(forKey: kReplaceSystemBattery)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kReplaceSystemBattery)
            if newValue { hideIfNeeded() } else { restoreIfNeeded() }
        }
    }

    static func readBatteryPref() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["-currentHost", "read", domain, batteryKey]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let v = Int(s) else { return nil }
        return v
    }

    private static func writeBatteryPref(_ value: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["-currentHost", "write", domain, batteryKey, "-int", "\(value)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p2.arguments = ["-currentHost", "write", domain, "NSStatusItem Visible Battery", "-bool", "false"]
        p2.standardOutput = Pipe()
        p2.standardError = Pipe()
        try? p2.run()
        p2.waitUntilExit()
    }

    private static func reloadControlCenter() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["ControlCenter"]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
    }

    static func hideIfNeeded() {
        guard isEnabled else { return }
        let current = readBatteryPref()
        if let current, current != 0 {
            UserDefaults.standard.set(current, forKey: savedValueKey)
        } else if UserDefaults.standard.object(forKey: savedValueKey) == nil {
            UserDefaults.standard.set(3, forKey: savedValueKey)
        }
        writeBatteryPref(0)
        UserDefaults.standard.set(true, forKey: didHideKey)
        reloadControlCenter()
    }

    static func restoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: didHideKey) else { return }
        let saved = UserDefaults.standard.object(forKey: savedValueKey) as? Int ?? 3
        writeBatteryPref(saved)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["-currentHost", "write", domain, "BatteryShowPercentage", "-bool", "true"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        UserDefaults.standard.set(false, forKey: didHideKey)
        reloadControlCenter()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverHosting: NSHostingController<AnyView>?
    private var dashboardWindow: NSWindow?
    private var titleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastStatusKey = ""
    private var lastLeftClickAt: TimeInterval = 0

    private let popoverSize = NSSize(width: 292, height: 500)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PowerStore.shared.start()
        ProcessEnergyStore.shared.start()
        Self.installPowerEventObservers()
        installMainMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            SystemBatteryMenuHider.hideIfNeeded()
        }

        createStatusItem()

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = popoverSize
        pop.animates = false
        pop.delegate = self
        pop.appearance = NSAppearance(named: .darkAqua)
        popover = pop
        attachPopoverContentIfNeeded()

        PowerStore.shared.$packageWatts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        PowerStore.shared.$levelPercent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        PowerStore.shared.$isOnAC
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        PowerStore.shared.$isCharging
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(titleTimer!, forMode: .common)

        NotificationCenter.default.addObserver(
            forName: .fathomRebuildStatusItem, object: nil, queue: .main
        ) { [weak self] _ in
            self?.createStatusItem()
        }
        NotificationCenter.default.addObserver(
            forName: .fathomOpenDashboard, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openDashboard()
        }
        NotificationCenter.default.addObserver(
            forName: .fathomMenuBarDisplayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastStatusKey = ""
            self?.updateStatusTitle()
        }
        NotificationCenter.default.addObserver(
            forName: .fathomDashboardPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resizeDashboardWindow()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            UpdateChecker.checkOnLaunch()
        }
    }

    private func createStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
        let item = NSStatusBar.system.statusItem(withLength: 52)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
        item.button?.setButtonType(.momentaryLight)
        MenuBarPositionStore.configureStatusItem(item)
        statusItem = item
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button, let item = statusItem else { return }
        let p = PowerStore.shared
        let mode = MenuBarDisplayMode.current
        let wattsKey: Int = mode == .watts
            ? Int((p.packageWatts * 10).rounded())
            : p.levelPercent
        let key = "\(mode.rawValue)|\(wattsKey)|\(p.isCharging ? 1 : 0)|\(p.isOnAC ? 1 : 0)|\(p.batteryPresent ? 1 : 0)"
        guard key != lastStatusKey else { return }
        lastStatusKey = key

        let img = MenuBarBatteryIcon.image(
            level: p.levelPercent,
            charging: p.isCharging,
            onAC: p.isOnAC,
            present: p.batteryPresent,
            packageWatts: p.packageWatts,
            mode: mode
        )
        button.image = img
        button.title = ""
        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        if let cell = button.cell as? NSButtonCell {
            cell.imageDimsWhenDisabled = false
            cell.lineBreakMode = .byClipping
        }
        item.length = MenuBarBatteryIcon.preferredLength(title: "", image: img)
        button.toolTip = p.batteryPresent
            ? "Fathom · \(p.levelPercent)% · \(String(format: "%.1f W", p.packageWatts)) · double-click dashboard"
            : "Fathom · AC · double-click dashboard"
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Fathom")
        let dash = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dash.keyEquivalentModifierMask = .command
        dash.target = self
        appMenu.addItem(dash)
        let closeDash = NSMenuItem(title: "Close Dashboard", action: #selector(closeDashboard), keyEquivalent: "w")
        closeDash.keyEquivalentModifierMask = .command
        closeDash.target = self
        appMenu.addItem(closeDash)
        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Fathom", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover() {
        guard let event = NSApp.currentEvent, let button = statusItem?.button else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
            menu.addItem(withTitle: "Open Menu", action: #selector(forceShowPopover), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Check for Updates", action: #selector(checkUpdates), keyEquivalent: "")
            menu.addItem(withTitle: "Open website", action: #selector(openWebsite), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            let quit = menu.addItem(withTitle: "Quit Fathom", action: #selector(quitApp(_:)), keyEquivalent: "q")
            quit.keyEquivalentModifierMask = .command
            for i in menu.items { i.target = self }
            statusItem?.menu = menu
            button.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if event.clickCount >= 2 {
            lastLeftClickAt = 0
            if popover?.isShown == true {
                popover?.performClose(nil)
            }
            openDashboard()
            return
        }
        lastLeftClickAt = ProcessInfo.processInfo.systemUptime
        performPopoverToggle()
    }

    private func performPopoverToggle() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
            setPopoverFastMode(false)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            attachPopoverContentIfNeeded()
            setPopoverFastMode(true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let win = pop.contentViewController?.view.window {
                win.makeKey()
            }
        }
    }

    private func setPopoverFastMode(_ on: Bool) {
        PowerStore.shared.setFastMode(on)
        ProcessEnergyStore.shared.setFastMode(on)
    }

    @objc private func forceShowPopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if !pop.isShown {
            NSApp.activate(ignoringOtherApps: true)
            attachPopoverContentIfNeeded()
            setPopoverFastMode(true)
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func openDashboard() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        }
        setPopoverFastMode(false)
        NSApp.activate(ignoringOtherApps: true)
        if let win = dashboardWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            resizeDashboardWindow()
            return
        }
        let hosting = NSHostingController(rootView: AnyView(DashboardRoot()))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let baseW = DashboardPrefs.shared.width.points
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: baseW, height: 380),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Fathom"
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: baseW, height: 380))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        dashboardWindow = win
        resizeDashboardWindow()
    }

    private func resizeDashboardWindow() {
        guard let win = dashboardWindow, let hosting = win.contentViewController else { return }
        DispatchQueue.main.async {
            hosting.view.layoutSubtreeIfNeeded()
            var size = hosting.view.fittingSize
            let minW = DashboardPrefs.shared.width.points
            if size.width < minW { size.width = minW }
            if size.height < 200 { size.height = 320 }
            win.setContentSize(NSSize(width: size.width, height: size.height))
        }
    }

    @objc func closeDashboard() {
        dashboardWindow?.orderOut(nil)
    }

    @objc private func checkUpdates() { UpdateChecker.checkManually() }
    @objc private func openWebsite() { NSWorkspace.shared.open(UPDATE_PAGE_URL) }

    private func attachPopoverContentIfNeeded() {
        guard popover?.contentViewController == nil else { return }
        let root = AnyView(
            MainRoot()
                .transaction { $0.animation = nil }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor
        hosting.view.layer?.cornerRadius = 14
        hosting.view.layer?.masksToBounds = true
        hosting.preferredContentSize = popoverSize
        popoverHosting = hosting
        popover?.contentViewController = hosting
    }

    private func releasePopoverContent() {
    }

    func popoverDidClose(_ notification: Notification) {
        setPopoverFastMode(false)
    }

    func popoverWillShow(_ notification: Notification) {
        setPopoverFastMode(true)
    }

    private static func installPowerEventObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let map: [(NSNotification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "display_sleep"),
            (NSWorkspace.screensDidWakeNotification, "display_wake"),
            (NSWorkspace.willSleepNotification, "system_sleep"),
            (NSWorkspace.didWakeNotification, "system_wake"),
        ]
        for (name, event) in map {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                DrainLog.shared.recordEvent(event)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            dashboardWindow?.makeKeyAndOrderFront(nil)
        } else {
            openDashboard()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        titleTimer?.invalidate()
        titleTimer = nil
        cancellables.removeAll()
        SystemBatteryMenuHider.restoreIfNeeded()
    }
}

private let fathomAppDelegate = AppDelegate()

@main
struct FathomAppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = fathomAppDelegate
        app.run()
    }
}

SWIFTEOF
echo "🔨 Compiling…"
swiftc "$WORK_DIR/main.swift" -o "$WORK_DIR/Fathom" -framework SwiftUI -framework Cocoa -framework IOKit -lIOReport -parse-as-library -O
strip -x "$WORK_DIR/Fathom" 2>/dev/null || true
[[ -f "$WORK_DIR/Fathom" ]] || exit 1
pkill -x Fathom 2>/dev/null || true
rm -rf -- "$APP_DEST"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$WORK_DIR/Fathom" "$APP_DEST/Contents/MacOS/Fathom"
chmod 755 "$APP_DEST/Contents/MacOS/Fathom"
cat > "$WORK_DIR/icon.b64" << 'ICONB64'
aWNucwADJBBpYzEyAAAKYolQTkcNChoKAAAADUlIRFIAAABAAAAAQAgGAAAAqmlx3gAAAAFzUkdCAK7OHOkAAABEZVhJZk1NACoAAAAIAAGHaQAEAAAAAQAAABoAAAAAAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAECgAwAEAAAAAQAAAEAAAAAARlFCsAAACcRJREFUeAHtW2tsHFcVPjP78K5fSRznaWrXSZsmcVMMiUJrAmqqIPpQ6goEqBUSKk8hAaqEUIRaKigtECERyh9+ARVCPFpRmgThVs0LtTF1wU0gdtNHSGIb5x0nfu2Od3dm+L7r3bCPGe/sy42wbzTZ2Tv3nnO+755775m7xyLzZZ6BOc2AVjR62/bJoNRLQuogIyQ6/s1mscSCOkP8Mi7NMiaaZhajvnACBu2VvoHBjaGT73QEzgzfql251KRFJ2tt0/IVY0CxfTSfbtrhmgl7UeNwfGVTn7FqTbfZ0twrzdqZQmR6J+CUvTx0vH976I3uB339RzdpA6fq5PJFsaMRkUQCOu1C9JahLUz3+0ULV4ssXiJ2S+u42db+D+ODHb8z1rXtlVbtnBcl+QmwbU2Ojt+x4MBfvhU4vO8e6T9aZY1cAl54oAav15Ii8kvyYo/3Nim+bdwkbdEbGkXa2qfiH97WNXrXvT+W9rq/wb5US0fZM5t90PYHfQOdtXufe1I/+OJaa+Df00L02Z3ujpY7VVpcFkT0ltVibb37rYntn3osZrbslq0aXdSxuM/b79p6cPXAA7XP/nqX3vX8auvMkIgPzVMj7ijuPa6kbbhseKg+dLoxYBh3mBtuPG227HpbDn3P0RPch/IT0Q/V7n32Kf3lPTdYly+o+fYew/OuHmsDbabtxCDA4tbZmYCT9rL6fbt36AdfusW6BPA+v1v/67ceNtN2YiAWASYnY3MJwKIXeuvY/YFX992j5jzYLFvBYqUZUdGwczheeKYWtHIppCdg3SIWYhIu6FklF92ALA/19jyk9f8z6DhpsgR4/grw2LfFePALYi1dKiqMSe+ModAvXJCqF34Pciand5j05yXcE0uo97WHjPUb/gwxZ9NF5RDgGxre6Os/skltdcWs9qYpWjyGkcykjyMfefhrEtnxTRE8dixB1IbCUr3r+2LjM6NwcQugARfiQgowEAtjF2JDuEgSrpVMAhDehp55eYs2eKrW5t5aYHSrTRlivu9GiW/uEHvZimT/JBEIlmJ33SuCwUX47Fzi4IZtuJ1dm3r0Wkyd82cl8Hq3+P5zWuyqkHN/t1pOPWAKnXhzy6Rtd2GnuBY2ZxJwTOoD54ZvZYSnghw3gQ71Wjyu3Dv61UfEWtEAAA6NOPIEX+XwjFXgKtG+ThKb1+U2QD/97IiEf/5TCf3hGXhDILeNWw0DNmBS2IARza6kmmaaWSN12silJhXeFrDfc+SNT35WJr/zhHIa/cSw+E6+K1rWNEgpLfTThi3mqpvFam2a1hGbktAff+PdEzh9uPACmwCjOwFxCWtGpGY6tvdoJtzVQiwe/dIjmJ8iwd17peaHj4p+daR8QROItBY2yOS3n5JY53alK3joJdHGRkF47kbmaDmmoMIGjOnPMz2gCoOGtzrwBePTm7nfa4m4xNfdJlbzCszTUal++geiXb0idtDNz91lzfSEMik7fvtHla4EdAYPH/CmR2GxRb2xAmO6Ho/0pXfJurcgeOEiNef1iwg8Ri6LFDI/s8S5foVMyqYOri9KJ3SXWkonINuCAtaO7K55v1dAdvkJyIvi+mowT8D1NR6zb828B8w+59eXxnkPuL7GY/atmfMekBkKl3MA4oi9+TLkNVZ30413Db4Mib/AcwA3eVn1lSEA4BMdbWJ8/m6RMA4xin0rJPBoTEK/fFH83f0goYBX4Cygbl/LTwBHbFGdTP7oy2Le1IQX/GtnD242zFyPkTfXNEt952OiRdyOkmYWMdPT8hOA0SYBVj3OHUanih/9lNX4TYOyKFObxC9SZS7lJ4AG8i2Ng4UX65J/MuQ0oKwyvPnRtOxSGQKohUdfOOMrnYCkLHxUolSGAB6/J5JXqa/s9ADKyj3SLwsfFSIAqOO4fDjdzSEgVQFQqcMZgnQrfKY8KdXPrWFx9RUggMCxXfkW4PR3MT5xhK1z++IoYkewgMbE4pjAr0CmgQsT3OJO4QKQBJiIASjTrU1x2FWv8hOAbTD6ua+I3bQJCSwESbAcQniDBiA6zgoDODbXk4ENCUmACBLCTxPf+ZsEgZO4QDV+Y2hQMmuefLwEqM5dy08AzuCDf90nsY+0Y8BJAFdDjC6DIeXqBMYRRYDkh3cEa3BVA+hC/CoEwCrpImksiUB/bfQKZO5P9ncGUmxtBQjQxHccURuzSMIAqBYvgM4ocHkb5AjSawTH5yzKO+ghuBRRqOPU4LSJRCCzD/Xlf3WpAAEwnD9rmTA2DuCOYXCKkNQnGeAaQG9JegyruG6oNQCyKDO9uXpe+n/lJ4A2KSywtuhAKA0pCVDbYOlgnSRUhgBqotFFE5BmaoqAtKpy3laGAHoAF35OWd6XUugMlFWqHBcbKkdAuT1gVgiYwpqNDEy12lBh2lR0IdClOjlvlQcULWRaNruTzOKNSXqPho0G2IAx3ehMDwhI1A5VT2pccVXwkt7U+702heAnhj2cchAYlVR4ohQzRMksRRBsITYBxnQxmQRMyrjd0DiM9NP2gnIEUlsdjcWlX70s4a7nxLjzgel9PZP0dP157jHyiAVCh15QMu0qRJGpI7aUzjwS1GO0ZUotsSFDZTy9SyYBG2Qs3tvU51+85D5hbqCHFBnbB8BIX4FribVypZjI0vT3HZHw/j9JVc8BeAFj+BIKPFGfQB4AMlDMNeuVDuqiTur2VBhRIochvrypT4AxvU+mBOTOGDetf9Vubp3wHHUBoP/4MVzHwXBYJh/fKYkPbBarbgFiGDCfiImGF56iLvaFDMqiTMqmDuqiTs/kIoIkJmKDQKxx/yuZHoB684amXmZd+4+8fqenTDHs01pkQqp/8oSMP/0LSWy6TUZ/BZe9eB6LT4nzP2UnAFhLlonU60hziShd1OkpCQNrEJOoE8BEbCmRqc8cAqRFzhkbb/9tzZGeDnllPxPX8hYaEnjtFan7+sMS+cYOKhOrZUXefgU1MCzx97wh1T/biWyxw8gP8p6BYre9P0ZMxJatM5cA+Jxx0t4T3LLtvuDg6U7r1LvTq3l2z6zvNCjw926p/+JncBq8RuUNTU+jjF0nq5eXr1gI4Uk6srx8J97BbmB4B4+8IL31Zolt2dZlrN2wR82nLJW5BLDBKu382L8iOxvODq3Vx0dvUcnSHvKF7SAcBqu2702sCaVuf1mG2lz9uZVRh5eC12i9calYWz/+9ti2zp3E5NTNmQC2fD7cM7H904/WRo1dKmOcSdPc1/MVxu7I5yl13POpmfE5R57gP3b/EDEQi1t7hljuZQ78wcTMBJCaOf0nM+m+MWf/aCqdBN7P2T+byybi/+QPJ7NhzX+fZ2COMfBfsbD/YHNgADcAAAAASUVORK5CYIJpYzA3AAAZsolQTkcNChoKAAAADUlIRFIAAACAAAAAgAgGAAAAwz5hywAAAAFzUkdCAK7OHOkAAABEZVhJZk1NACoAAAAIAAGHaQAEAAAAAQAAABoAAAAAAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAICgAwAEAAAAAQAAAIAAAAAASI4EdwAAGRRJREFUeAHtXQlwHMd1/TM7ewO7OAkCoIAQAEWJEkmRBCSa1mFKNiuSXYokW6VEOe1yLrts53C5cltKxWWXnVhlO3YSO47jOElZUVlilFhKSRZJUyRjmqApHqJFEQADkAAI4j52gd2dI+83dsgVhb0GO4tdeLo4nMXMdPf
ICONB64
base64 -d < "$WORK_DIR/icon.b64" > "$APP_DEST/Contents/Resources/AppIcon.icns"
cat > "$APP_DEST/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fathom</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.chopstickshq.fathom</string>
<key>CFBundleName</key><string>Fathom</string>
<key>CFBundleDisplayName</key><string>Fathom</string>
<key>CFBundleVersion</key><string>0.2.13</string>
<key>CFBundleShortVersionString</key><string>0.2.13</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLISTEOF
codesign --force --deep --sign - "$APP_DEST" 2>/dev/null || true
xattr -cr "$APP_DEST" 2>/dev/null || true
echo "✅ Installed $APP_DEST"
open "$APP_DEST"
