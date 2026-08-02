#!/bin/bash
# Fathom installer v0.2.3-Beta — IOReport package watts + sleep/wake drain events
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
EXPECTED_HASH="3366edd60ac1d5ab00e11bf7d7a9db43a7db7bc84cf42740b00db6a4dc52c2d1"
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

// MARK: - Constants

let FATHOM_VERSION = "v0.2.3-Beta"
let FATHOM_CHANNEL = "beta"
let UPDATE_CHECK_URL = URL(string: "https://chopstickshq.com/fathom/version.json")!
let UPDATE_PAGE_URL = URL(string: "https://chopstickshq.com/fathom/")!
let UPDATE_CDN_BASE = "https://chopstickshq.com/fathom"
let SUPPORT_DIR: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fathom", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

// MARK: - Theme (macOS dark menu / Control Center)

extension Color {
    /// Near-black panel fill (Sequoia menu surface)
    static let bg = Color(red: 0.11, green: 0.11, blue: 0.12)           // ~#1C1C1E
    static let card = Color(red: 0.16, green: 0.16, blue: 0.17)         // elevated group
    static let cardElevated = Color(red: 0.19, green: 0.19, blue: 0.20)
    /// Subtle light-gray hairline border
    static let border = Color.white.opacity(0.12)
    static let divider = Color.white.opacity(0.08)
    /// Primary / secondary labels
    static let labelPrimary = Color.white.opacity(0.92)
    static let labelSecondary = Color.white.opacity(0.48)
    static let labelTertiary = Color.white.opacity(0.32)
    /// Monochrome semantic tokens (no chroma)
    static let accent = Color.white.opacity(0.92)
    static let nGreen = Color.white.opacity(0.78)
    static let nOrange = Color.white.opacity(0.62)
    static let nRed = Color.white.opacity(0.88)
    static let nPurple = Color.white.opacity(0.70)
}

/// System SF Pro — Control Center style (no custom display fonts)
func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .default)
}
func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

// MARK: - Shared UI (macOS menu dropdown)

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



// MARK: - CPU package power via IOReport (Apple Silicon, same as rNitro)

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

// MARK: - Battery + Power

final class PowerStore: ObservableObject {
    static let shared = PowerStore()

    @Published var batteryPresent = false
    @Published var levelPercent = 0
    @Published var isCharging = false
    @Published var isOnAC = false
    @Published var chargeWatts: Double = 0
    @Published var packageWatts: Double = 0
    @Published var packageSource: String = "estimate" // sensor | estimate
    @Published var pCoreShare: Double = 0 // 0…1 of CPU time on P-cores (approx)
    @Published var eCoreShare: Double = 0
    @Published var cycleCount: Int?
    @Published var healthPercent: Int?
    @Published var capacityRaw: Int?
    @Published var designCapacity: Int?
    @Published var timeText = "—"
    @Published var statusText = "—"
    @Published var wattHistory: [Double] = Array(repeating: 0, count: 60)

    private var timer: Timer?
    private var wattRing = Array(repeating: 0.0, count: 60)
    private var wattIdx = 0

    func start() {
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
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
                self.wattRing[self.wattIdx % 60] = self.packageWatts
                self.wattIdx += 1
                // chronological last 60
                var hist: [Double] = []
                for i in 0..<60 {
                    hist.append(self.wattRing[(self.wattIdx + i) % 60])
                }
                self.wattHistory = hist
                DrainLog.shared.recordPower(
                    level: self.levelPercent,
                    packageW: self.packageWatts,
                    chargeW: self.chargeWatts,
                    charging: self.isCharging
                )
            }
        }
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
        // Prefer IOPowerSources for menu-bar %
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

        // Enrich via AppleSmartBattery
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
        // Charge watts
        let voltage = propInt(service, "AppleRawBatteryVoltage") ?? propInt(service, "Voltage") ?? 0
        if let amp = propInt(service, "InstantAmperage") ?? propInt(service, "Amperage") {
            let signed = signedMA(amp)
            if signed != 0, voltage > 0 {
                let w = abs(Double(signed)) / 1000.0 * Double(voltage) / 1000.0
                if snap.charging && signed > 0 { snap.chargeW = w }
                else if !snap.charging && signed < 0 { snap.chargeW = w } // discharge draw
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

    /// Package power: IOReport Energy Model (sensor) when available, else loadavg estimate.
    static func readPackageWattsDetailed() -> (watts: Double, source: String) {
        if let sample = IOReportPowerReader.shared.sample(), sample.cpuWatts > 0.05 {
            // Prefer CPU package channel sum (same as rNitro CPU watts focus)
            return (sample.cpuWatts, "sensor")
        }
        // Fallback: loadavg × envelope
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
        // Best-effort: perflevel counts (not always present)
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
        // Without per-core busy time, approximate share by core counts under load.
        return (Double(pcores) / total, Double(ecores) / total)
    }
}

// MARK: - Process energy (local estimate of Activity Monitor “Energy Impact”)

struct ProcEnergy: Identifiable {
    let id: Int32 // pid
    let name: String
    let path: String
    var energyScore: Double // arbitrary units, comparable
    var cpuPercent: Double
    var samples: [Double] // recent scores for sparkline
}

final class ProcessEnergyStore: ObservableObject {
    static let shared = ProcessEnergyStore()
    @Published var top: [ProcEnergy] = []
    private var timer: Timer?
    private var lastCPU: [Int32: Double] = [:] // pid → total user+system seconds
    private var lastWall = Date()
    private var history: [Int32: [Double]] = [:]
    private let historyCap = 60 // ~1h at 1/min if we downsample; we store last 60 samples

    func start() {
        timer?.invalidate()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
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
                // Energy impact proxy: CPU% + wake-like weight from thread count
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

// MARK: - Local drain log (JSONL, capped days)

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
        // occasional prune
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




// MARK: - Screens (rNitro section layout)

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
            MonitorRow(label: "Time", value: power.timeText, valueColor: .secondary)
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

struct MainRoot: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header — Control Center menu title row
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.labelPrimary)
                Text("Fathom")
                    .font(uiFont(15, weight: .semibold))
                    .foregroundColor(.labelPrimary)
                Spacer(minLength: 8)
                Text(UpdateChecker.displayLabel(FATHOM_VERSION))
                    .font(uiFont(11, weight: .medium))
                    .foregroundColor(.labelSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.border, lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            MenuHairline()
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    PowerSection()
                    EnergySection()
                    WhySection()
                    SettingsSection()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 360, height: 560)
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
    }
}

// MARK: - Auto-update (rNitro pattern → Fathom CDN)

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
        // Prefer beta channel for this build
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
        if head.count >= 2, head[0] == 0x3C { // '<' HTML
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

// MARK: - App delegate (menu bar)

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverHosting: NSHostingController<AnyView>?
    private var titleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let popoverSize = NSSize(width: 360, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PowerStore.shared.start()
        ProcessEnergyStore.shared.start()
        Self.installPowerEventObservers()
        installMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.image = Self.menuBarSymbolImage()
        statusItem = item
        updateStatusTitle()

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = popoverSize
        pop.animates = true
        pop.delegate = self
        // Match dark menu surface
        pop.appearance = NSAppearance(named: .darkAqua)
        popover = pop

        PowerStore.shared.$packageWatts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        PowerStore.shared.$isOnAC
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)

        titleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(titleTimer!, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            UpdateChecker.checkOnLaunch()
        }
    }

    private static func menuBarSymbolImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let img = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Fathom")?
            .withSymbolConfiguration(config) else { return nil }
        img.isTemplate = true // black/white adapts to menu bar
        return img
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let w = PowerStore.shared.packageWatts
        if w > 0.05 {
            button.title = String(format: " %.1fW", w)
        } else {
            button.title = " Fathom"
        }
        button.image = Self.menuBarSymbolImage()
        button.imagePosition = .imageLeading
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Fathom")
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
            menu.addItem(withTitle: "Open Fathom", action: #selector(forceShowPopover), keyEquivalent: "")
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
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.releasePopoverContent()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            attachPopoverContentIfNeeded()
            pop.show(relativeTo: .zero, of: button, preferredEdge: .minY)
            if let win = pop.contentViewController?.view.window {
                win.makeKey()
            }
        }
    }

    @objc private func forceShowPopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if !pop.isShown {
            NSApp.activate(ignoringOtherApps: true)
            attachPopoverContentIfNeeded()
            pop.show(relativeTo: .zero, of: button, preferredEdge: .minY)
        }
    }

    @objc private func checkUpdates() { UpdateChecker.checkManually() }
    @objc private func openWebsite() { NSWorkspace.shared.open(UPDATE_PAGE_URL) }

    private func attachPopoverContentIfNeeded() {
        guard popover?.contentViewController == nil else { return }
        let root = AnyView(MainRoot())
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
        popover?.contentViewController = nil
        popoverHosting = nil
    }

    func popoverDidClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.releasePopoverContent()
        }
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
        forceShowPopover()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        titleTimer?.invalidate()
        titleTimer = nil
        cancellables.removeAll()
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
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CQ0TExEAABETEwsOgRMLDgsTExEAABETEwsOgRMLDgsTExEAABETEwsMgQsLDAsTExEAABETEwwHgQALBwwTExEAABETEwwGgQALBgwTExEAABETEwwHgQALBwwTExEAABETEwwIgQILCAwTExEAABATEw4IgQkLCA4TExAAABERExMRgRAEERMTERGAAAISEBGDEgIREBKPAIEAhf+DAAK2TjyDOQI8TraAAH+qORwXExEQEBETFxw5qgAATRwWFjhQm5tQOBYWHE0A/zoXEk19XWdnXX1NEhc6//85FxBnOQsPDws5ZxAXOf//ORcQZTsKDg4KO2UQFzn//zkXEGJabnBwblpiEBc5//85FxBcke/q6e2RXBAXOf//ORcQXZPZ1tbak10QFzn//z05FxBegb+8vsKCXhAXOf//OhcQYm+ampmab2IQFzr/AE0cEUaFd3l5d4VGERxNAACqORwULTc2NjctFBw5qoAAA7ZOPDaBNQM2PE62gwCF/4EAgQCF/4MAAttgTINIAkxg24AAf8xIKCIeHBoaHB4iKEjMAABgKCEhR2C0tGBHISEoYAD/SSIcXpJve3tvkl4cIkn//0giGntIFhkZFkh7GiJI//9IIhp4SxcbGxdLeBoiSP//SCIadmJhZGRhYnYaIkj//0giGnGPzMnIyY5xGiJI//9IIhpwntjW1dedcBoiSP//NEgiGnGRysnMz5JxGiJI//9JIhp1hbq5ubqFdRoiSf8AYCgcVZ2NkZGNnVUcKGAAAMxIKB87gUQEOx8oSMyAAAPbYEpFgUQDRUpg24MAhf+BAGljMTQAAJIFiVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAACAKADAAQAAAABAAACAAAAAAAL+LWFAABAAElEQVR4Aey9B5wk133f+a8Ok3dmMxaLBTYgLIBFJgJJMIBgpinblERZtkQ5SLZ0ztadT7I/li35zvLZn7NsfXQ+yzqd7VOwacoKlm1SYgRJEASInPMmLHYXm2dmJ3Z31f1+r7u6q3tme2eme6qrqn8P6O2eruqq977vvfr93/8lMwUREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAEREAERSBABL0FxUVSSSODng5x98KGcbX8gZ5PH8ja6K2fTZ3JWuICyszmJMVacRKDPCJwzK28MbMNW32aO+Taxq2KnHvLtmw/49vOe32cwlNxVEJABsApYmTo1CDx76PCgDRZGLDcyYoVgzCp4ecGIWX7EgmAYr0Hz/AEzr2g5L2++5czz8MJ/vs+yo/KTqUKhxKSUQGC5XGDuv4C11Dc/qJgFJQtyi6izC3jNmVVmLfBmLe9dtDJe/uysLZRn7YE9PB6kNO2KdgcE9ADvAF5qfvrE8RHzC+PmVzZbYXCzBXiv+BOWz0Hoc0NmfhFinzcvh/JQazAEeKDk8Ejx8Rzhw4Vfe/hbQQREINkEAtTUHKJIIz2XZ5WGye4MdnyJA4GPMzxW7BK+n8ezAEZBbtK8/DkrL5zDb/AqT9ndO2eTnVDFrlMCMgA6JZi0378YDNj0qU1oAWy3YnEHHgLbUNknUOsh9l6BjwLXUsAXaBHgQQBxd5+TlhDFRwREYJ0J4FlAwyBPHeCTofps8IIy/oS3IJiE8X/aSqWT8ACesg3bz9sBb3Gd46TLx0hABkCMsNflVk8ERbMzW61iV6GSXoVKux3SvgEVuOis/iAH+x9uwU5Fnl4ABREQgXQQqHbRdRJXGAPs7vPhB2TdR3eCZ9NoTJxC4+Jty9vbZlvP2N1eqZOb6Le9JSADoLf813b3R8+Omy3usnx+D6z3K2HFb0QFhRvfVVQ6/FY+8IfCTi9AoYi+wwAVPV8T+kq1bJTxACgt5q1cxploLfBvBroUfYwjcC0I943+EQERiJsA624O/feu7uPmhRykn/W54FtxoMK/q1GK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AMhoxipZIiACIiACItCOgAyAdnR0TAREQAREQAQySkAGQEYzVskSAREQAREQgXYEZAC0o6NjIiACIiACIpBRAjIAMpqxSpYIiIAIiIAItCMgA6AdHR0TAREQAREQgYwSkAGQ0YxVskRABERABESgHQEZAO3o6JgIiIAIiIAIZJSADICMZqySJQIiIAIiIALtCMgAaEdHx0RABERABEQgowRkAGQ0Y5UsERABERABEWhHQAZAOzo6JgIiIAIiIAIZJSADIKMZq2SJgAiIgAiIQDsCMgDa0dExERABERABEcgoARkAGc1YJUsEREAEREAE2hGQAdCOjo6JgAiIgAiIQEYJyADIaMYqWSIgAiIgAiLQjoAMgHZ0dEwEREAEREAEMkpABkBGM1bJEgEREAEREIF2BGQAtKOjYyIgAiIgAiKQUQIyADKasUqWCIiACIiACLQjIAOgHR0dEwEREAEREIGMEpABkNGMVbJEQAREQAREoB0BGQDt6OiYCIiACIiACGSUgAyAjGaskiUCIiACIiAC7QjIAGhHR8dEQAREQAREIKMEZABkNGOVLBEQAREQARFoR0AGQDs6OiYCIiACIiACGSUgAyCjGatkiYAIiIAIiEA7AjIA2tHRMREQAREQARHIKAEZABnNWCVLBERABERABNoRkAHQjo6OiYAIiIAIiEBGCcgAyGjGKlkiIAIiIAIi0I6ADIB2dHRMBERABERABDJKQAZARjNWyRIBERABERCBdgRkALSjo2MiIAIiIAIikFECMgAymrFKlgiIgAiIgAi0IyADoB0dHRMBERABERCBjBKQAZDRjFWyREAEREAERKAdARkA7ejomAiIgAiIgAhklIAMgIxmrJIlAiIgAiIgAu0IyABoR0fHREAEREAERCCjBGQAZDRjlSwREAEREAERaEdABkA7OjomAiIgAiIgAhklIAMgoxmrZImACIiACIhAOwIyANrR0TEREAEREAERyCgBGQAZzVglSwREQAREQATaEZAB0I6OjomACIiACIhARgnIAMhoxipZIiACIiACItCOgAyAdnR0TAREQAREQAQySkAGQEYzVskSAREQAREQgXYEZAC0o6NjIiACIiACIpBRAjIAMpqxSpYIiIAIiIAItCNQaHdQx0QgMwSCwIwvHy8FEbgUgZxn5tVelzpH34tARgjIAMhIRioZyxCg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SkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAr4i8P8BbFqe0fpIUrkAAAAASUVORK5CYIJpYzA5AACSBYlQTkcNChoKAAAADUlIRFIAAAIAAAACAAgGAAAA9HjU+gAAAAFzUkdCAK7OHOkAAABEZVhJZk1NACoAAAAIAAGHaQAEAAAAAQAAABoAAAAAAAOgAQADAAAAAQABAACgAgAEAAAAAQAAAgCgAwAEAAAAAQAAAgAAAAAAC/i1hQAAQABJREFUeAHsvQecJNd93/mvDpN3ZjMWiwU2ICyARSYCSTCAYKYp25REWbZEOUi2dM7WnU+yP5Yt+c7y2Z+zbH10Pss6ne1TsGnKCpZtUmIESRAEiJzzJix2F5tnZid2d9X9fq+7uqt7Zntnpnuqq6p/D+jtnq7qqve+7736/d//JTMFERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABERABEUgQAS9BcVFUkkjg54OcffChnG1/IGeTx/I2uitn02dyVriAsrM5iTFWnESgzwicMytvDGzDVt9mjvk2satipx7y7ZsP+Pbznt9nMJTcVRCQAbAKWJk6NQg8e+jwoA0WRiw3MmKFYMwqeHnBiFl+xIJgGK9B8/wBM69oOS9vvuXM8/DCf77PsqPyk6lCocSk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yRIBERABERCBdgRkALSjo2MiIAIiIAIikFECMgAymrFKlgiIgAiIgAi0IyADoB0dHRMBERABERCBjBKQAZDRjFWyREAEREAERKAdARkA7ejomAiIgAiIgAhklIAMgIxmrJIlAiIgAiIgAu0IyABoR0fHREAEREAERCCjBGQAZDRjlSwREAEREAERaEdABkA7OjomAiIgAiIgAhklIAMgoxmrZImACIiACIhAOwIyANrR0TEREAEREAERyCgBGQAZzVglSwREQAREQATaEZAB0I6OjomACIiACIhARgnIAMhoxipZIiACIiACItCOgAyAdnR0TAREQAREQAQySkAGQEYzVskSAREQAREQgXYEZAC0o6NjIiACIiACIpBRAjIAMpqxSpYIiIAIiIAItCMgA6AdHR0TAREQAREQgYwSkAGQ0YxVskRABERABESgHQEZAO3o6JgIiIAIiIAIZJSADICMZqySJQIiIAIiIALtCMgAaEdHx0RABERABEQgowRkAGQ0Y5UsERABERABEWhHQAZAOzo6JgIiIAIiIAIZJSADIKMZq2SJgAiIgAiIQDsCMgDa0dExERABERABEcgoARkAGc1YJUsEREAEREAE2hGQAdCOjo6JgAiIgAiIQEYJyADIaMYqWSIgAiIgAiLQjoAMgHZ0dEwEREAEREAEMkpABkBGM1bJEgEREAEREIF2BGQAtKOjYyIgAiIgAiKQUQIyADKasUqWCIiACIiACLQjIAOgHR0dEwEREAEREIGMEpABkNGMVbJEQAREQAREoB0BGQDt6OiYCIiACIiACGSUgAyAjGaskiUCIiACIiAC7QjIAGhHR8dEQAREQAREIKMEZABkNGOVLBEQAREQARFoR0AGQDs6OiYCIiACIiACGSUgAyCjGatkiYAIiIAIiEA7AjIA2tHRMREQAREQARHIKAEZABnNWCVLBERABERABNoRkAHQjo6OiYAIiIAIiEBGCcgAyGjGKlkiIAIiIAIi0I6ADIB2dHRMBERABERABDJKQAZARjNWyRIBERABERCBdgRkALSjo2MiIAIiIAIikFECMgAymrFKlgiIgAiIgAi0IyADoB0dHRMBERABERCBjBKQAZDRjFWyREAEREAERKAdARkA7ejomAiIgAiIgAhklIAMgIxmrJIlAiIgAiIgAu0IyABoR0fHREAEREAERCCjBGQAZDRjlSwREAEREAERaEdABkA7OjomAiIgAiIgAhklIAMgoxmrZImACIiACIhAOwIyANrR0TEREAEREAERyCgBGQAZzVglSwREQAREQATaEZAB0I6OjomACIiACIhARgnIAMhoxipZIiACIiACItCOgAyAdnR0TAREQAREQAQySkAGQEYzVskSAREQAREQgXYEZAC0o6NjIiACIiACIpBRAjIAMpqxSpYIiIAIiIAItCMgA6AdHR0TAREQAREQgYwSkAGQ0YxVskRABERABESgHQEZAO3o6JgIiIAIiIAIZJSADICMZqySJQIiIAIiIALtCMgAaEdHx0RABERABEQgowRkAGQ0Y5UsERABERABEWhHQAZAOzo6JgIiIAIiIAIZJSADIKMZq2SJgAiIgAiIQDsCMgDa0dExERABERABEcgoARkAGc1YJUsEREAEREAE2hGQAdCOjo6JgAiIgAiIQEYJyADIaMYqWSIgAiIgAiLQjoAMgHZ0dEwEREAEREAEMkpABkBGM1bJEgEREAEREIF2BGQAtKOjYyIgAiIgAiKQUQIyADKasUqWCIiACIiACLQjUGh3UMdEIDMEgsCMLx8vBRG4FIGcZ+bVXpc6R9+LQEYIyADISEYqGcsQoOAvls2j6A8PWLBxzLwNI2YDKvbL0NJXKCvB9Kx5kzNmc4sW0BhgWZb3yKMAAEAASURBVKFBoCACGSSgJ2EGM7XvkwTh9+ZLZhMj5r/vFlt84HYr377PyldtsWBk0Cyfx0O97ykJQJQAHUOVinmzC1Z4+6wVnj1oxYeetdzjr5pNzlowVJQhEOWlz5kgIAMgE9moRNQJLJbMGx2y8g8/YHOf+4iVbrrGgiKKOR7uVvGr3QD1k/VBBFoIwENU3rnF7N03mfeXPm7Fl4/a8G9+1Qq/97AFM/PwCMAQUBCBjBCQAZCRjFQy0ECbh9v2nv028w9/1Obv3V8V/FLZrAzxVxCBFRGAK4CGoqE7AP8u3rzbFv/5X7ahH/yAjfzj3zIPHoFgaGBFV9JJIpB0AjIAkp5Dit/lCeBJ7aHlX/5zD9rFf/Q5q4yjnx99uAoi0DEBjAtgmL/7Biv91s/a2C/8phX+0zcsoCdA3Ugd49UFektA0wB7y1937wIBbwHi/+OftOl/9hNWYR8//lYQga4SQJli2WIZY1ljmVMQgbQTkAcg7TnY5/Gn27/ymftt+ud+pDrDz7lv+xyKkr8+BMq++fmcK2vjZyct//vfUXfA+pDWVWMiIA9ATKB1m3UggP79YP/VcPv/mPk5FGWJ/zpA1iWbCKCMsayxzLHsGceYKIhASgnIAEhpxvV9tNnvjwfx/P/yQ1a+YjMexBjox1FbeonBepcBlDWWOZY9lkFX5vq+QgpAGgmoCyCNuaY4Y3h2yfwP3m5zH70bA/7QHxtoRJaKRYwEUOZY9gbvv8W8bz5rNqjpgTHS1626REAegC6B1GXiJeBhlbaFP/tgdY4/V/xTEIE4CaDMcX0JlkGWRQURSCMBGQBpzLV+jzMX9bnmClu472aM+FcfbL8Xh56lH2XPlUGURbfQVM8iohuLwNoIqAtgbdz0q14SYB/sHddZZcu4pvz1Mh/6/d6B78ogy2L+0InqEtP9zkTpTxUBGQCpyi5FlgQ8uF8rt+zlKEANwFKR6C0BlEGWxcLvfUtjAXubE7r7GgioC2AN0PSTHhMo5K2ya7u29u1xNuj2IICdJl1ZRJlUEIG0EZAHIG051u/x5Xg/Pmy53K/PzX36HYjS31MCLIMsiyyTLIsaD9jT7NDNV0dAHoDV8dLZSSDA/dkLsl2TkBWKAwiwLLJMKohAygjoKZqyDFN0awTY2sLLkwdARaKHBNwMVJXBHuaAbt0JARkAndDTb3tOQM/enmeBIiACIpBSAjIAUppxfR9tKn/46nsYAtAzAiqDPUOvG3dOQGMAOmeoK/SKgJr/vSKv+4YEVAZDEnpPIQF5AFKYaYpyjQAevhoDoNLQSwJahbqX9HXvTgnIAOiUoH7fGwLO9epZoE2AesNfd60SYPmTF0ClIaUE1AWQ0oxTtEVABERABESgEwIyADqhp9+KgAiIgAiIQEoJqAsgpRnX99F2XQCgIPdr3xeFngIIy2FPI6Gbi8DaCMgAWBs3/arXBMIHrwyAXudEf98/LIf9TUGpTykBdQGkNOMUbREQAREQARHohIA8AJ3Q0297S0Ctr97y193VBaUykGoCMgBSnX19HPlQ/NUF0MeFIAFJD8thAqKiKIjAagmoC2C1xHS+CIiACIiACGSAgDwAGcjEvkxC2PKSB6Avsz8xiQ7LYWIipIiIwMoJyAOwclY6UwREQAREQAQyQ0AegMxkZZ8lJGx5yQPQZxmfsOSG5TBh0VJ0RGAlBGQArISSzkksAazEriACPSMg+7Nn6HXjLhCQAdAFiLpEDwjUWl7aja0H7HXLBgF5ABos9Cl1BGQApC7L+j3CfOKy3R999TsTpb93BMJyyBiEZbN3sdGdRWA1BGQArIaWzk0WAbW+kpUf/RgblkEFEUgpARkAKc04RbtKQGMAVBJ6SUD630v6unenBGQAdEpQv+8NgVrrX2MAeoNfd60RkBdKRSHFBLQOQIozT1EXAREQAREQgbUSkAdgreT0u94SCFte8sH2Nh/6/e5hOex3Dkp/KgnIAEhltinSbsC1Hr4qCL0moDLY6xzQ/TsgoC6ADuDppyIgAiIgAiKQVgLyAKQ15/o83s7zr9ZXn5eCBCQfZdCVxQRERVEQgdUSkAdgtcR0fjII6KmbjHxQLGQBqAykloA8AKnNOkW8Pg5AKESgVwRkiPaKvO7bBQLyAHQBoi4RPwEtABQ/c91xeQIqi8tz0bfJJyAPQPLzSDFcjgBbXuFrueP6TgTiIKAyGAdl3WOdCMgDsE5gddn1JSDP6/ry1dVXTkBlceWsdGayCMgDkKz8UGxWSiCA4zV8rfQ3Ok8Euk1AZbDbRHW9GAnIAIgRtm7VZQJyv3YZqC63agJq/q8amX6QHALqAkhOXigmIiACIiACIhAbAXkAYkOtG3WVQNj6Vwusq1h1sVUSCMvhKn+m00UgCQTkAUhCLigOIiACIiACIhAzAXkAYgau23WJQNjykgegS0B1mTURCMvhmn6sH4lAbwnIAOgtf919jQTCxVfC9zVeZhU/W8bSaP3qkpG55IFV3F+nJpEAi4ByN4k5ozithIAMgJVQ0jmJIxDUWl7uvaPYhSqO9/Ajr+eFj3W8e+gp44uP+vo7j0fOqf+Y1+GFwne/9nf4Hh7DKdFQvx+/DK8bPUGfE0kgzOZERk6REoH2BGQAtOejo5ki0PK0dsKOKpAr4jVgluf7YO3v2vdevir6fK8bAPzYRqTrVgnvR+GvvQzvfgV/l/HOV6n55b6vHa8bEGEG4H7ulm3uG56qdxEQARFYAQEZACuApFMSSKDWkK43vJdEsXYC3yjWFPA8RX7IrDBSfednir6HauCEfhlxrYt5eANe8DIhahzw2mG4pIDjmryPMxRC42DRrMLXAl7z1c80GGgkuPNq8ahfc5m4h/fV+/oRYDbUsmL9bqIri8D6EIg8ndbnBrqqCMRGIHS9U4DZoi8M4zVmVhytfnYt/VpL3kWKossPtaf4ErHvRswj6lC/1yWu6zwS8EDk8TLEOwwuXjXvgR8aBjAKynM1AwFGQkBvAs6pqxEY1I2D8EJ6FwEREIEGARkADRb6lDYCFEYneog4xb2Ilv3gBrzjxVY+vwtb46FxEL4nNq1I07KGAo0adlEwnVHjgN0L6DYIvQU0CpxhQOMAxgK7GugxCIPj4SyD8Bu9d0LA5VUnF9BvRaB3BGQA9I697rwWAuhD98oUPLzYyh+awGtjVRTZcnaD9HDhUOjd+1pulMTf1NSmNU3svqDBQ09HGGgUUPzZheCMglmzUs1j4LoScJyXq3sJZBSE6Fb1zrxgWSzB2Mqxm4keJgURSAcBGQDpyCfFEi19r1Sy4Iodtnj3fVbe/x6zTXvBpVaE64Ifae32FTUIUZNhAEF3AxthJA2MV0nwuBt8SKMAXQglGAVlvvDZDUiEkDV1IcgoWLYIhWWNxmZuyPwtV1nlrnssd/SIeaffsaBAT43WWFuWnb5MFAEZAInKDkVmWQJltGQnJmzux37cFj76Sats2242iv59txNbvwr+sqRavqRRwK/cP9VjbKXmOCYC3QgYA+mOcWYCxxbQEKBBQMOgPvCQnoIa46bug34yDsiPLPFy3haUvUF4nZznacQWx2+00i+/y3Lnz9rgV//Ihv6//9dsahKM9XitFjr9m1QCKqFJzRnFq0qA7tVNm+3iL/6fruVv82i9LkKshtCyjY6wF6+VEXC2QE3Qwl+wJZvngEl0I9hmvHCcYyvoFaAhwK6D+tgCjivgbISo4QVjwNkDGTIKwlY+GeXwmOSA0kF4Uij8bnwJXf3gVPOqBOBR2bLVZmGklm++1cb+/v9sduG8ugTITyGxBGQAJDZrFDES8CBEsz/516viP4uWqcI6EaiJWXh1tvY5pqIANwFFj4Gi78YVwAigYeCMAr7jVYlOUayeXh+AWbUOal8m8a1mEPGNNgwNyyLSzjEVAxxUCm9JIRxfUuPUZADV0kRjFWV08e57bQ5lduSf/oIFGhOQxAxXnGoEZACoKCSXAFz//t5rbeHBj5nNQ2QUYibQYhTw7pyFwLUT6tMUeU7EMCjDQ+OMA77zRY8BuxH4inoNeLGax8C91T7z63UJjCcv7P6p3QH3ZF+9mzJaWx+CM0n4ovHD7hKG0BuwJP7Vw0v+RVllmR36/G+Zd/ggjAc9Zpcw0heJIKCSmYhsUCSWI+ChRVXaf5P543C9LkBM1j1AEC4pRlEBiX5ujVTrNVr/jp4fXoffRYUpek7SPodxjsYXaawPOESLOQwUzPpsBHYn0HMQebkBifjeGQg8lwbCctcPL7jK93DMghusx7EPeNzRgGFrnp6N0MNRXwzKZT6iwLQxHozPGgK8ViyzZZTdgTdfx6BAPWbXQFE/iYGASmYMkHWLNRLAgzgYg/vVPchbr8GHde2B3XpoJX+H4sBz+cB3QkUxwoBDt9gO3ylaeIUi5t4pChQr90P+mB9qoRYfd220LPnOVqRbZZACFIpQTYgoSHm8eJyfmZ5wGqO7IuPFD9F7uAPJ/GdJXJmeWhrZh96UX0wbOfId3oHQS+AGJII9v+PxqHFQF+QWHo4ZWZN5jXfImvevf+bx2ssRrF3HCT6+CN/dMVxvxWGZc5H3ruw2XXPFF9SJIhALAT51FEQgkQSCnGe5M6cgwhTdDkKT2ENYKOp0VbMP2w1wYx82XdUR4bnUg9tda4VxcfrSIlbhT8M4tbZOuVwxW6hsnbqli/F3aCSk2jggh1YWNBD4ogGEw05HlxHTkNma3nHP+m1rH+qGxJouuLIfoczmTp8ylmEFEUgqARkASc0ZxQtCWLTCi89b7p0T5nPqHwdZrSSE4spzKeolCPziDF4Xa1PcIP5O7OvKgBMpRPwB/+Fn9we/WHuoX6/NJShGTFcZBkhDqao/CFurrt+9ZhjQde1eNQOBnoMlhkE0XW3unZhDoTAzQmmL+zIQMfAvd+qEFV563pXhZc7QVyKQCAIyABKRDYrEsgTg0vXeecdG/vNv28Wf/pnqQMC2LXMoLgWVrfqFi+YtTFWFn619upRdCMWd6uwUuvY93nqmPWE8wvdalBgfpseHAUMjph5BnOcGr6H61vqxgyJc7Hw57wGMBbq96+nDhVzaepbAWoL64I2G48CAjXz+t13ZDQZhqCmIQEIJyABIaMYoWlUCAR6mg7/zH83fus3m/uznMK0KRbYMF75zHVMw8aJIQvBtHouv8LWI6YJo4Tu5q3sD6GOuhdTpINPJEL7jo49EuMV74DmYh6HD4JhA+DmojV6CARoFGNHuNkWiUQB2dW8Bfu84pA5GNa1J+5cGWbFoHLg6/Bv/zgZQZll2FUQgyQRkACQ5dxQ3J2pcZGX4//olKzz9hC1832esvO9a83dfA93HQ3fuQvVF0XetfIikE8KI4GeWY80gcEZOLZHOA0KPAbwgc1iIhoF97DSc6B0Ip7nVvQUwFupGAc51HhYZBY7bZf+plTV4W3IXp6343DM2+Ie/Z8XvfAuGKspflOtlr6UTRCB+AjIA4meuO66WAB6kQSFnhW8/ZMWHv2mGKVYz/+Qf2PyN+9DaRwu4tZXf9/pFw6BmHJA1RZ1jDPiaC70FECgaBexCoDEwwPnv7ELg9DgYBWzR1q+B31+q64XX76dQL2tINAeTVuZs4KXnbOzv/QPzsBdAAE5q+fdTgUh3WmUApDv/+iv2cKnyAetxRcDF2roAamWtsAzUDIKot8DNhoCILUzXroFznFEA13URhgC9BexGcEZB2IUQMSzYh5B5wwDpDZmF3pV6dxO45SqWP3HQvGNvVef7h+euMFd0mgj0koAMgF7S173XRoAPWb7Y0udLYY0EQjEP33EZzkiowMBawKwJO4sXjtEb4MYV1LwF9BTQQHADDuktiA44ZFRoGNTe+ZaagLQ6FDUeFHyuZsjupXmMMaGhxK4VGk4MLIPo9w+Yfi75m3ljqJps/ZsdAjIAspOXfZgSPqhrD+s+TP36JRlMo1gpbNzvvgQxnMMgSwZ6XtzYAhgAXDefxgA9Bc4woLcA31MUnYem6WLV3/fUQAjTF4kXxZ4LP3HGyCJEnqLPqaOcfVHBVFIu/kQozvikwROGyDXCr/QuAikhIAMgJRmlaLYQoICEr5ZD+rPbBEKRC99D9hRNCCQFMwxOIGEcuFUOYQRgLYeqpwBGQQEvehLcGAOIKFvOzpDgdSPXDq9Vf3fWQv2v9h8udR1cg4YMB4o6Lwf772nUcMBk7cUxEmzd0xhwAddielzcaqLfGhX+3fpd9cf6VwQST0AGQOKzSBEUgSQTCEUyEkcKbTjocKFFHZ3g00CoGQDunUYBHkXOaOD3+OxWB6SXIXyF9wnfeT9c212e73xBuF1Lnu8UerTcueBT/Z2iX/suXGK4Hm0KPUJowFT/0r8ikGkCMgAynb0ZThwf/OErw8lMb9Jqgtrasnd5Rs8BBJqfXah/CL+ovVPs+TFyrfBj9Ez389o1aAg0Lhw9q3Ed16rnIRgXreFSUWk9L/y73e3Cc/QuAgklIAMgoRmjaIlAtgmE4s5ULqfqy6Ueans5ga677Jf7vb4TARGIEpABEKWhz+khELa8LicI6UmRYppGAmE5TGPcFee+J7CMD6zvmQiACIiACIiACGSegDwAmc/ijCYwbHnJA5DRDE5JssJymJLoKpoiECUgAyBKQ5/TRUAP33TlVxZjKwM0i7naN2lSF0DfZLUSKgIiIAIiIAINAvIANFjoU5oIhK1/tcDSlGvZi2tYDrOXMqWoDwjIAOiDTM5iEt3EMTx8VzqBLIsMlKbeE+CyAyqDvc8HxWBtBGQArI2bftVjAuF6L+69x3HR7fuYAAwAlcE+zv+UJ11jAFKegYq+CIiACIiACKyFgDwAa6Gm3/SeQADHa/jqfWwUg34loDLYrzmfiXTLA5CJbFQiREAEREAERGB1BOQBWB0vnZ0kAhqBnaTc6M+4sAwqiEBKCcgDkNKMU7RFQAREQAREoBMC8gB0Qk+/7R2BsPWvFljv8kB3ru5OqDKokpBSAvIApDTjFG0REAEREAER6ISAPACd0NNve0dAHoDesdedGwTCctj4Rp9EIDUEZACkJqsU0SYC4YNX7tcmLPojZgJhOYz5trqdCHSDgLoAukFR1xABERABERCBlBGQByBlGabo1giELS95AFQkekkgLIe9jIPuLQJrJCAPwBrB6WciIAIiIAIikGYC8gCkOff6Pe5qffV7Ceh9+uWB6n0eKAZrJiAPwJrR6YciIAIiIAIikF4C8gCkN+/6O+bhJix8VxCBXhEIy2Gv7q/7ikAHBOQB6ACefioCIiACIiACaSUgD0Bac65f4x02+MP+f/XB9mtJSEa6w3LI2IRlMxkxUyxE4LIE5AG4LCKdIAIiIAIiIALZIyAPQPbytH9SFG199U+qldIkEZAHKkm5obiskoAMgFUC0+kJIRCKvx7ACcmQPo1GWA77NPlKdroJqAsg3fmn2IuACIiACIjAmgjIA7AmbPpRzwmELS95AHqeFX0dgbAc9jUEJT6tBOQBSGvOKd4iIAIiIAIi0AEBeQA6gKef9pBA2PKSB6CHmaBbW1gOhUIEUkhAHoAUZpqiLAIiIAIiIAKdEpAHoFOC+n1vCIQtL3kAesNfd60SCMuheIhACgnIA5DCTFOURUAEREAERKBTAvIAdEpQv+8NgbDlJQ9Ab/jrrlUCYTkUDxFIIQEZACnMNEWZBLDwunZiU1HoNQG3G6U2Aeh1Nuj+ayOgLoC1cdOvREAEREAERCDVBOQBSHX29XHkQ9erugD6uBAkIOlhOUxAVBQFEVgtARkAqyWm8xNFQM7XRGVH30VG9mffZXmmEiwDIFPZ2UeJqbW8Aj2B+yjTE5hUeQASmCmK0koJaAzASknpPBEQAREQARHIEAF5ADKUmX2XFLW++i7LE5dgeaASlyWK0MoJyAOwclY6M0kE9OBNUm70d1xUFvs7/1OcenkAUpx5fR91PHg9PXz7vhj0EoDGoPSSvu7dKYGYPADnGM/mR3U+7y/7+PZiilKn5PT73hJoLk29jYvu3t8EVBb7O/9XmvpltQ1NGKeFTRdBiXKa2fTlevwRjwegvDGwQSQ0ai4HuQCLuTVXHY+TujSxaz0yOpPXROmJFqlMplGJSjaB5idYsuOq2PWYALTNaVwkGtRAamE05PD3AjQzhhBPc3vDVp/JbE2Pt5wDNycDoJWT/hYBERABEUg5gWW0bVkNpFZSM2MI8XgAZo75NjDkWzRJhZxvOa/clEZaR7k8vlpiKzSdpj9EwBURFBONAVBZ6CUB54HS46qXWZCSe6OQUNuocVG3JTWQWhgNucA3amYMIR4DYGJXxWbP0AsAg6eq7r6XCwIvV6ILol5/CCePb+pfxEBAt0gnAZYRbMSCQpTO+CvW2SDgNqTKRlKUinUkwOcVtS1iAPDJBR0sUQvrd652jPtGzYwhxNMFcOohtP5zFQvv5vueFQo+Bj+UmtLoDIBi01f6QwREQAREQARSTyAPbaPG1QMbvNBAaiE1kYEaSa2kZsYQ4vEAfPMB3z55qoQuAHgAalZAcaDi5/MLeTfor2EAWZEGQOTvGCDoFiklwGKiopLSzMtItFX+MpKR650MFBSnbc33oQYatNBKi+z7hvjTEPBLRs2MIYRt8vW91c97kP7CQrV/v3Yr9nsUCvPNN4Z9UBxo/kp/iYAIiIAIiEDKCVS1LeoBQIKogdExAG6cALSSmhlDiMcDwIQEwSJaaxwDUA9BcWC21QFgg4P14/ogApckELb+1QK7JCIdiIFAWA5juJVukXICrdoGLXQaGE0WveQGrYwpxOMBYGJ8f96qTo5a0vJBZWBoekk6HaSIlbDkBH0hAiAg4VcxSAoBlcWk5ESC4wFNazUAENuqBuYbJYgaSa2MKcTnARgszli5BAoNcQ+Ghmea0wkXweBQy0CJ5jP0V78TQPnhNJoKBslqBHa/F4bep59l0JVFlMmmAV69j5pikCACKBtO21paLks0kGMAqJUxhfg8AKXybHWIY5iyiucPj043zYnkg50GQL7JVRD+QO8iUCXAB+7MRT1wVR56T4Ciz7LIMqkgApciQE2jtkXXAMBnp4FWabSKOQ3AaeWlLtTd7+PzAOS9i1bx0cSvpdX3vPL4+GTD94GEOQNgEOMFC+gFQTdIeG5306yrpZ2AX7H8mZNIBcpSUwFKe8IU//QR8KplEWUSI7rSF33FeP0JQNc8zgBgF0DEAOCjixqIxQAaBkAAjcznYFHGE+IrsWUYADmvYSb7FS8YG5/BtEAMDvQbQ/+LgMQXDQAFEViGQID6kj/yBvvKZAAsw0dfxUgAZZBlkWVSQQQuSSDUtegJ0D6ngdDC+tceNJJaGVOIrwvAn53FOgBc+rea2Eo5Vx6fmPGLBXQN1AKtI7T+bXi4yVIKD+tdBByBfMEKR16z/OR5lKb4irDoi0ATAZQ9lkGWRUOZVBCBZQlQ16hp1LaIB4DaRw00aGHtd57TSGplTCG88frfbgFjAPI2h9Z+3drxRzfMB8XByfoXjAX6SryR0SZQ6x853SFVBHI5886esoFXn0WlgmuNvjS9xCDuMoCyxzLIsmgokwoisCwBiL7TtMjYNmoetY8aWP8NtZEaSa2MKcRXah/YswA/GUc3VvXejXYcKPtDQ2zGRZKL0ZJj4/ibtVlBBJYnwNIx9J0vW25xAcWnurwES5FeYhBHGWCZY9ljGdSTavk6qm9DAjAAnKY165zTvsGBcnX1P3cuNjeBRlIrYwrx+a087Nv2+OkpC/JX1cU9V/T9kQ2n7dyZ+lfuwwYYAOpTi6kIpPQ2aH3l3njRhp7+js3e+yAGjcZWZ1IKTNHuKgGsWDr0va+7MhjQC6UgApciQC2jpkVNRXzltA8aiAFvtV/m0ZIJpqB9sdmU8RkATGIlOGc5TpwNLaGKV57YeMreqqWfb3SXjG2o9qlF+ksiZ+ijCDgCKCk29D/+oy3uu8XKm7ZoKpbKRTwE4MotnDnlyh7LoIIItCWA8SFO06J6Bol32hedAuihC6Bi59peq8sH4+sCcBGvnLMgsvUhpwJu3X46iI6MICSMAfCGNBCwy3mdvcuxT+30CRv7nV+1XAkbS3JAIG1nvcRgvcoAyhjLGsscy57WLMneY6WrKWKDllrWMq6Nmkfta54CSG2ERsYY4jUAcvlzlg8aWwCXS7nS1u3n/GKxMe2BBsAA1gIYHcNDLJb9EGLEnfJbRS3YTpLCDS+6FeCKzT//mI194VfN42IsvDYf/goi0E0CLFMoWyxjLGssc9jFrXt36Fad6FYd7V7K+vtK0DCnZdC0aDuXmkftw+q4DQ2mNlIjYwzxdgGUt01a4ewcSGCYPx7TmP7gb9wyEwwMnfVKpQ315zYr2sQms3eOx4hCt2pPAK7OMmy3Lthk3vBIV8d4YEMNKz76FRtfmLOLP/hTVhnfjNW0NCagfX7q6KoIYB53fuqcjf2XX7XC0w9zE5dV/bztyRzEyjrRaWDdZB1Vt0SnJLv3e3oAqGU08CqcBV/NHWoeta95CqA3a+Wtk927+eWv1LA+Ln9u52e8x+ZhBU1ipGPjvsPDJX9s/PiSQX/s01VB7px5l67gFt+Zw+aNXMqpk25PPqQ2QaC7PHCKD2Q+mMf/75+zoZeeMC+PgVnuHp1EtkvwdJmUEkDZQRliWWKZYtnquviTDMsp60QnxjWiyrqZRx3VokRJKm7IGKdlkTjB4HOaB+2rf0tNpDZSI2MM8XoAOLrx0bOnLVe5plpckVIUerhCjg68c/y99XTTbTKxES42VAyu9qbQewIotLnpKbQw8JQpdODCR3ZWrthp2AQDg1+rU/i6lTgaAd7xIzb66/+7DdyKmvS+T1lp9/UGa7tajtilRBepczXV/U3dur2uk2oCVFAkAOXcjSXhWhOL81bkTJOHv2jF579rQbnc3ZY/eaE8si6wTnRkAPBaqJuujjINCskgAA1zWhbtzsajh5rXlN+enzM/fzrOGQAEFK8BwDvmvROoYNgFofYALpfypW07jmNugI8Hc9UzwIf06Aa3eEIwBY+IFtkgud4G5gFX3pvDUg7jmNKyVv2EBvvbr7Rg23bz3jpcne3RzZRxHwmUn8JT37QNeGj7V19npf13WPmaG6yyabsFw6OoZ/EX+24mUddaHwI5uGg9lO/8+VNWOPqaFV99xnJvYZnfElYrZyudK7l1O2APAdYF1okmQVjtfaj5rJuso3perpbe+pyPxqsb/Q8tcw2P2l2oddQ8dNc0WlI5aKIHbYw5rEOJvkwKKiVYObkSrO2qmYpxAKWdu86g9XbeW1yg378KawCtObhOgskLl7mgDsdCAK0KDx6A/IXzVt4IA2CtjhkaABMjVrnhgBUOYT3/9RBjtoDgDaAh4B16xQbffNEGeR+0tOgNCNgfp0ZSLMUmNTeBQetBjNnqt3kMU4IxwHIScKZJN/v7W4HAq8C6wDphDYdw61mX/xv2Oesm6+iS7tTL/1pnrAcBPn/o/oeWRXeLpNZR8yL9/ziOAYABtDHmEL8BsOHMeZvZjm2AbSMewj5XQfInNs6WN4wfGzh7ZgscYjUEEJwt280OQyQUek+ArQpse5o7+bbZvt2dxQfP1MV3v9+Kf/QH9dzu7IKX+DUNAXoEQkcXuxwW5qX9l8Clr9H2YJmh6PMVQ/AgEqwLWAK2YwPA1U1uTRxT3GPAk/JbwACghkWeOGz3lqB11DxbWKzqLz3fnl2wMWhjzCF+A+DAgUV7FKtoeIZRL7WOEayGVN687dDAuTO31xWB4wC2bK1a3xoHEHOxWP52Hlyhebba398YrrH8mZf5Fi2d0ns+aMFWVI44u3j4cOdLQQSSQADPNdYB1oWOWv9MC20W1E3W0SCP8TUKvSfAMUnUsGj/Px4/1DprWgEQAwB9O2XUxphDtc895pvCz/Y2/G2NJzH6QhZ37jmEtn/DsUzRx/rJbg1lGQBx59Al7udZ4ZUXorl0ifMu8zXGEVau3mml+x9EUdB0vcvQ0uGMEmDZZx1gXcAKcJ0FPC4LrzyPazQeq51dUL/uiAA0y2kX9wCI6Bc1jlrX1P9PLaQm9iD0yAAYP4aC2ujx4jiAXbvf8TE3sokBLKgcW4lRC6rpBP0RJwH2h+bxkPFmkHVdeM7Mf/Zz2CYTfZ9wgyqIQF8RYJlH2Xd1oNOEoy6yTuZhnLsxC51eT7/vnAA0y2lXy/gRahy1rqn/n1roURPjD70xAHKvnMVAwAtw91fvz3EA4+NzlYmNB70mFy36UHbAOo4sGxA/It2xTgD96bmjhyx/9HC1z7J+YA0f4Owq3XmnLX7k0+ahX15BBPqJAMs8yz7rQH0vmLUCoPsfdZJ1c11mKqw1Xv38O2iW0656nzZkDNpGjaPW1XcAdP3/0EJqYg9CbwyAu+8uYVQkpgMGjZE2iMnilde8EuFVdZ1s2lrdS1mtxB4Uj5ZbogBzlHHxKSyD2o3RI2gEzf3k30Y/6BVNo2Rb7qo/RSBbBLCcMMs8y37T826tqURdZJ3UDIC1Auzy76BVHtf+h3ZF3f/Ma6dxUdWlBlILqYk9CNGoxHv7Yu5Q08ZAi+X8wp7rDvv5/Gw9Is5NNmweBQJTdBQSQACzAQa+/dXOBy0xKWX8f90em/urfxermOEPBRHoAwIs6yzzLPusAx0HSIerk5r/3zHKrlyA00mpWcMYjBlpuFLbqHEGravfh5vjUQt7FHpnAIxuQZ+HT7Gv9iZjHEB5x84LlQ3jhzhVIhpyO3fVT4t+r8/xE+CCKPnnnrT8kaPd8QJgDODcZ/+sLX7mz2ERlobtF3/KdEcRWH8CLOMs6yzz1o3xr2j9sy6yTrrFitY/CbrDZQlg1VSnWY0TqWnUNmpcpP8fQgcNdFrYODfOT70zAG70ppHQk7CQGtZQLucvXnn1i00AOIIS1pQ3CpdKxJpqOkd/xEcArQzv/Fkb/PoXu2MAwC1GG/Diz/wjK33gozIC4stJ3SlmAhR/lnGWddfucWW/w0jAAGBdZJ3UCoAdsuzGz+n+p1Y5r3VjUhsv7bQNGle/TVX7TlpVC+tfx/mhdwYAU+l7b+LZ32jul8v5+X37X/NzucaoMIr+yIh5bqlMdQPEWTguda8Aq+oNYBEfbwrZ1Mi9S51++e+RrQH6zKb/6S9b6X0flhFweWI6I2UEnPijbLOMs6x3PO2P6UfdYx1kXWSdVEgAAbr/qVXQrGiDlZpGbTNoXD2W1D5qYA9Dbw2A0eIhOLAwIrImI+wG2LX7bGV84s2oXUA+3lW78U9vo9vDfErWrbHBRf5VLK/77a+j+dGlqKEvNNi4yab/xb+x0vd91rx5GBeR+bNduosuIwLxEuB8cJRllmmWbZbxrvT7MxWoe6yDrItu47R4U6a7LUeAo/+pVZHg3P/QNGpb3f3vNA/a5zQwcnLMH3urqLdOoD+kchIbBDXiUShWFnbtfraJAyvRNnQDjE9IFJrA9O4POmYG//O/R2sdyt0NLwCTQiMAG2dM/5N/aXM//XO4AXbx0xTB3mWy7twZAZZdlGGW5SmUaZbtrok/W/+oe6yD6hntLJu69mvqFDSKWtXaeHGaBm2r34uaR+2jBvYwNIS3F5Hg9sAFew0C0pCQxYXCwvW3vOYXCxwjUA0s4QODlrvqmiVgw1P0HjMBbHBRePIxG/zGV/GQ6+K92R2AdU1n/8pP2fSvfd4q7/0QlsnAMGeuGKgnXRdB61LrQoBlFGWVZZZll2WYZRmezu64/cNIs/WPusc66DabCb/Xe+8IwABwGgWtij6rqGXUNJSLRj8NNc9pHzSwh6G3BgAT7k0fxL/NswF27jxf3rT1pahdwNUAvav3OEOAP1PoPQGW3KF/9yvoh5zDAKQuxocXRuOpdPvtNvWvf8Mu/otfs8q996OsoETM4V5lGAQyBroIXJfqiADLIsqkK5tc7AVllWWWZZdlmGW5K/P9w0iirrHOse71VD3C+Oi9SgDC7zQqsnItNYxaVoam1d3/yD78YLamfT2l17BIehWNu6+dtMfPHMU2XDdiYSA4gRGwMuD8vhueKp46cS/+qnoHYF3ZxCbLbd9h/ttHYVA3xlK43+if+AlwLMALz9jw7/yWzf7EX8Z8vi5HAasFBvCULXz8E7b4wMet8PxTGPH8JSt87zvYp/2weRcvoqw4lwFKiYdzu3x/XU4EliHg2mwUfZY3bhk8Nmb+1futDOFfePCTVr71LgsGcRDlt+NV/pa5Pz1uw7/5W67uBUPoJlPoPQEs7pTbcZXTqKj7H7vbBtQyalo9koGHQmNH7R5oX49D7w0AAvCDly3n7a+bsyUsCnTjbQdHnn/i7cLM7C5ArGJiC3DPdWbH36r+rX97TiAYKKIl8q9tESOcy9ft684CQdFUMevp/Ufel+56l5XueReEH+uewwjk7mcFLH8anHnH8jAGchUOIoj+WJ9FoMsE8Bj3MeK+Mjrm+nrL1+y1yt7rrILuyWCsWHXzsxnTjTn+y0Udtyi8ctDVOdY9hYQQwPMpR23Cexhc63905G1qmUHTwu/hLQ2c5tW/6N2HZBgAZy8csa0bz8Oi3kg0tJb8DRsWFq/a/Xjh9Zd31R/qHGRxxZXmbdxswYVzmvfau3LTuDNaQN650zbyS//Ypn/5/4FQ46G0HiLMa8Lzz1cAz0P52mutfMO1tsCuBx4LX/ioIALrSoDP+PAFx6Sb0sfhXXT1r2fAPTm2gHWNdS7gIFmF3hOgLkGTDNoUbf2zjFDDqGU2MzPgIgo7AU6B80bNS0BIhgHwqesX7LFTr0DR78eTnFUKlWmhMHfTnc8NHXzto165POa+o9uNOwTC0qo8/Si+4tNfodcE+CAqfusrNvwfft1mf+p/Wv8HIcWeraxqh1Gvk6/7i0A8BOj6/9Vfd3VN4h8P8hXdhTv/wQtEbUI/f/0nWPr3IjWMWlb/0rn//VeMmpeAkCAFHXoJYwDm630lXBPgmt1nS9t2PN20QyAXWrhmT3Wv5chgiwSw7OsoBCj8Q7/2SxiZ/C2MDOxrFEq8CHSfAOoU6xbrGOuaQkIIQIO8sfHq4D+OR6oFaha1ixpWH/zHcQDUOIPWJSQkxwC4b/wsxP8w+lAafSWLpfzczXc8BmwNs4pegKEReAGubXa3JARo30aDG5Fg+tPI//Z3sS/565it0bcklHAR6C4B1CXWKdYtNx2WdU0hGQQ49Y9aBE2KzkyiZlG7DBpWjyi1jRpHrUtISFhJGnwWgwGrXQAEVFrML9xw07HyxNYXOaCiHugFQDeAN4KeARoECskggI2CvJNv2/jf+xuWP/EOXGL/f3tn9hzHlZ35k5m1YQcIgAsIkgAp7hS4gYsoUSK1dbfci6O7Q9EOjz0zD+4Oh+2JmPDEPI0j+s1/gB/nabyE7XaPwuOWJTXVksiWRFHivoki2VxAQVywEGsBtWbO92WtWQVAhEmRWahzpWJVIbOqMn+Z937nnnvuuf44LD0KJVCxBFCHWJdYp1i3BHVMi08IQHuoQW5genHvH1pFzaJ2UcPyR+tqGzTOR8VfBkBfE6cD3sGjAA2wYpt6PsQUr4JhQNFHVi036rIIvI+4Vu+hMGHTF+el4X/+qVhDMHS1varee0HP/OEIUPxRh1iXWKeYDE2LjwhAe1wNYobHoo4otYqa5TlSd+wf2kaN81HxlwHwuoGufeoMfPuF7n48EYAr5XqqsflKmRdg9Vr1AvjoZsodCgOUrFOfSsNf/lSsgQEdDsiB0Wcl8KAE6PZH3Wn4y5+5dUmD/h4U3GPaL9f7hwa5uUiyP+tO/YNWUbME2lU4Go7/Q9uocT4q/jIACKZ2yRX8O4TJAAUvQCiQntrw9GEmVcizy3kB1qzzXID8dn3xRAm4RsDJY9L43/6rWNdvaGDgE70a+uMVRQABf6wzbt05+YlO9/PjxWPvn9pT2vuHRlGrBJqVP+yMlg1ltS3/Zz+88J8BsNlIYAjgDIIBC8c2HQvGenZdSTW1XC7zAnSvE6NBFwnyw81Uegw0AswLZ6XxT/+ThD7BtE3ODij4dkp31/dKoLoJsG6gjrCusM6w7mjP34e3BOf9Q3MMaE9Z7x8aRa0SaFb+yKll1DRqm89KQWT9dGDTk1jf0hiGWBSOL2Da05u2vo/xlSLLCg6BGswIWLcpnz7AT6ehx4LLEkZ+7NtfSj08ATV/93/QtQGVIseYMlICSiBbJ1A3WEdYV1hnWHe0+JAA5/1Tc6A9Hqc0tIkaJdCq/FG7GgYtczUt/1ffvCgIrG8OCQdysDuGzG6nAbcwDMBYgJ6dV5MtrRfL8gKsWiNGa7vHGvPT6VT9sSBzn8Snpfav/xcCmv5crLu31RtQ9TeFAnAJZHv9rBOsG6wjrCvCOqPFfwTg+qfWGNAcT++f8/6hTdQoz9g/NYxaRk3zYfGnAUBQU5MX4DYZ8ngB+Odtu34DBwyTwmYKYwFQWcyNWHWraNQgt1mffUKAi6ZgCeHQW29I43/5kUTe+CUuLQzlkE+OTw9DCTxuArj3WQdYF1gnWDdYR7jAkBafEoDGuFpDA43aky3UJGpT7r377Kb9hYZRy3xa/GsA0GIKBo57YgG4SNDGnr7kkmWfeWIBsBKT0dEpZucqTypGnzKv6sNyIjWYz3xb6v7qv0vjn/2xBE8cz0wVVEOgqu+Lqjp53uvQD977rAOsC6wTrBtafEwAaX6pMdQagebkCrWImkRt8iz6w7F/aphPe/88fv8aADw6u/lzjPjf9eQFSKSsyd7979sBC2vBeou5aasYrERFlpl3D33nCwKBgJvONHD0sDT87A+k4X/8mQRPnsjEB3DY0993pS8Q6kFUGAHe07y30bnnvc57nvc+64Cb2hd1QouPCUBTqC3UmNJCLaImCbQpv43z/qld1DAfF383tb109TufePhxjYBVqwdj3Wvf83gBEJkpTS1irt/iGZvxfFbf+IqAw8QmuG6hd/5VGn76E2n68/8skbffEnNyPBMjwJ6Sv+9QX/HUg/EZAd67vIcR2c97mvc273He67znee+7dcBnh62HMwMBTvujtkBjeN1yhRpELaIm5XP+5zZSu1wNy//Bdy/8PynLQdz/Z4M/RhVajYUUMmsCmKZjxmOBll/+7V8Epqc6kR8gA5ZrMadtSX/4rjiDSEVrFQwy35HXA/ISoNcmmUB1wqjoqtWSfPaAJF54WVIbe8RehGmebExZ7+h543Nh+A1vtCiBJ0yALSnvUTY52XvVvD8mgUvnJHTkNxL8+LCYfddx2+LG5WI+RevGP+Ej15//OgIcYm5fItb+V3B9cXGzHma2Vama2v6RH//x39jhSAqGQUZPHQPuHPu67G5HoJPh65bK/wYAL85Hgx0YM/sJeLNqZYDWRJKRE8c2Nn722z/xzBZgAM3wgKSxPK3DcRqtaF93e/tvO8bauO45G0p72XJJw+2W7Nkh6Q1PS7pzJbxqi8SpgfeAXlPewZVxF/uPsx7RwxFgS8QHuiXGdFzM0fti9d/Cwj3nJXjulFifY2mTO1+5hq3DoDFL3fwPB/wJfJquf3Qkrech/q2LoeuFsX9oS3p89/P/O9a791LRvH8D94QtSfknea799hM44nn9ZOU0nceHXkZ2wF5UtcIMgHAk2fLG3/1B6N6dvXkvAE8fFc25eFrSF05rpZvX7eDDnWl9pzgShJYWQwZOY5M4bYsljYe0L5UUjAGpq3O3GRo97cMLuPAOyaEIYOVLiUYlANGXwbvI2T8gBh/jY5lt6Hg4XLhHvZCVfQOgM2Jt2S7G5u2eAHP2/hNLlh0b+eEf/aPEi5L+IKIDs9FOyK4274wAn1KoHJN00j4mtcZT8AE0uBYWgaZS1sS+l95pfvMX681kHIMz2cK5mhivMQcQg4GHVsIcmAp8RgPq5BtRGAFoYI3REQleQWyN7UjQdcfh7+rpqcCLW8GH7N536D/xvjMh9jQ+sUyvg9ei0fwVfGGLDh2dD3PxMldLPD1/7JIOhkaoPdSg/CfoobaNUYlCqyqkVI4BcHDxpBy9+zFq2WuodJkoDAYELu0Ymd7Y86u6c8f/CMwzHg1WToiGuW2XOEcOiUN3sgpEhdyScx1mprF1G1pNJzgXKN2mBJTAwxCAhhjIxEgNcTuQRYF/+FqHmkPt8fT+bcdEDNrHcnBp2Qy1hzmUb/KzHFOvnHJoyUV0B69hWmDBcIH7JfrsS6dSbUtO0i2TL7xgLW1ibtmBy5WxF/Lb9IUSUAJKQAkogdkIMN0vtQMaUhr1T62h5njEn5pEbaJGVVCpLAPg5+j5B4KHxbCRK7NI7VNJc/z5V39lh8NDHvYMJsOKTSbTNuK1FiWgBJSAElACcxKAVlAzqB2lukGNodYINKfoO9D3hCZRm6hRFVSKT6IyDru3EUsFG0fRrS94ATgUsKxjNPr0zn/NDw/kzgauHHNrrxgtrd4Iztx2fVYCSkAJKAElQAKMH4NWUDNy0/3yYDD0TI2h1njn/EOLqEnUpgorlWcAEHBfG8L7BZNqi4YCsPzi1J7nzseXrzzsWSyI8QDhGrF2PiMGE8/wvRYloASUgBJQAsUEOO4PjaBWUDOKtYKaQm2hxhRN+cM+rgZdz2pS8bdVxOvKNABeN9JInP0ezLUpjO8XzgErBk68+P13kvUN173xAJi2gzmc5lYEdGhRAkpACSgBJTADAVcjSub7U0uoKdQW70p/1B5qELSImlSBpSCelXbwexqHJRA4glCAwjkgE5ONBEGTz738z3YwOOE5JcYDdD0l1vrNZeM6nv30jRJQAkpACVQXAegDtYEaUTbuDy1xNQXaks/259KB9lCDqEUVWgriWYknsGPReRgAF+CHQcaNbEkmrMRTG+5Et+xkGkZvQAYiO43N28RcubrsIuc+rs9KQAkoASVQRQQY9AdNoDaUzRjjuD+0hJqCVOWFOf+u5kB7XA2qXFaVbQAw6aKV/AAemgGMxRQuTjQamtr3/Jn4itXveoYCOP6PsRxzx14x25bACKhIr03l3m165EpACSgBPxFgsh9oATWB2uAZ94ewUEOoJcj6iAUcsoVaQ83JaE9FB5VVtgHA69HbMSVB89diOgm8KyQCQDzA2KvfP5RobTtTZgSEQmLu3i8G0sqqEZC9qfVJCSgBJVBNBJhmHBpALRBoQqn4UzuoIZ5xf2oMtYaaQ+2p8FL5BgAvwLa2r3D1juACFrwAXJnJMJ2xV37wL6naulseI4BJghoaxNr7vBi1tYjj8I4UVPg11cNXAkpACSiBuQigzWfbTw2gFhRrALWCmkHtoIZ4xv1djYHWuJoz1w9UxraFYQCQ9a72MzAC+CjEAyA/gN3SFp048K2/Z+5mzyWh+x9Znqw9MAKy69J7tusbJaAElIASWHgEKP6c7oe23830VzIU7Ob5h2ZQO0rm+0NboDGu1iwMLAvHABCsu1w/hHgAo8+THyA+HUh0P3VvYs/+v8cqgcwgWCgI/hAs9mDuflYMrtylOQIKbPSVElACSmChEeBcf7T1bPPZ9pdG/FMjqBXUDIF25E+f8/2pLdQYas0CKQvIAMAV2bw5IYHJtzFGM+IJCkSSoPj23VejPTv/CQvJeHMCc3pgx8rMDcFV59QIWCC3tp6GElACSqCIANt2LhLHDh/a/DLxhzZQI6gVJcl+8CFoCrWFGrOAysIyAHhhtnePStL4d0zniDNcI3+tEMUZ3XfgTHT902/AkvMO+tMI6OwSaxesQtcI8G7Of4e+UAJKQAkogcojwAXh0LazjWdbXyb+nO4HbaBGeCL+qSHUEmoKtWWBlYJALqQT24egwACiNBG+gdMqzAyAJyD64rc/nu5e/2bhj9kTpxGwolus3c/hRsFwgAYGLqQ7Qs9FCSiBaiXAthxtOtt2tvGl4k8toCZQGzw9f2oHNYRaQk1ZgGVhGgC8UL1tX4glh9Hb5zkW9J7pgr/zg/diXWvf9swM4GdynoC9nBaCdQPUCCAVLUpACSiByiTANpwBf2jTZ+r5UwOoBdSEsul+1A5qCLVkgZaFawDwgu1sPwn3zTExi5IEcXogcwR85/d/HVu5+tCMRkDHCgnsOyBGDRaEwOpQWpSAElACSqDCCHBlP7ThbluONr285w/xhwZQC1zxpzbkCjWD2kENWcClcMIL9SQdx5BPB16GEbATjoBk/jRNzO8MBtJN//7Ga5Fb11914OvxFMYCjAxL+tiH4oxj6IfvtSgBJaAElID/CWBqn9HY7Pb8hUvBl0z1c3v+FP/f++FbkkxZnrn+nEpuOydlz+LfwINcIgz+P/X5HOHC9gCQBC/grSPvY1YA1w3A4H620NrDhecNEOta8za25bZknnnD4Max9r+EVJGLy6xH7876TgkoASWgBHxBAEO5bLPZds8k/mzr2ebPLP7QCGoFNWOBiz+vVYnq+eLyfTMH8YETkLqh7+CUsRygU+YJaHj3Vy/WXLv8XUwD9BpFJt4m4mKf+lTsW9eznoDqwfbNXAz9ViWgBJTAoyaAzjo6blzYx9yxZ+Y4LkT7T69Z/+bEK997v7znzw6ic1GibW/LQcM7XfxRH6pPvq+6lOzEiaCkul7DxI6NHiOAFyMcSdYffufZ2svnfwh3UCEBBLdlF4lwLp6V9GUsPpj7W+aV/qsElIASUAJPkkA2f4u1fgu6eFvzbbbnkDDPfwpT/SYPINo/Hit4g92dIP62XJLAzbekt7fQQfR8wcJ7U10GAK8fjQB71bfLPAHcVlOXqDv63va6cyd/YqRTNZ7BHxoB8AY4N69J+sxnrldATI0LIDYtSkAJKIEnRoCB2oz037ZbjK41mdlbRQndKHIOMvwxyU9030unZbpoZT/3oLM9f7PvnWoSf5569RkAPGsOB9QOfUssYwuCPbyunrq6RPj0Z2sbPvvwD61EYlF5cCCcA8MDkj75iTgIEkTqSH6jFiWgBJSAEnjcBDh1m7FaO58RaS2P1WKwXzoUuj+xe/8/uBn+ipf15bGaSPGbdi7IVNuvq8XtX3yJqtMAIAGO9X868JIY1g5xOHCEWQG5UhNJhm78bknDkUN/GJiaXOUUWZPuLpwREIuJffa42H2IC6B3gA8tSkAJKAEl8M0TYJuMh7kK4/1bd4lEIuWR/miTU7X1fRMvvPoPbm5/JILLH5i7Wiwacid9CtH+76H9RsKA6ivVrVqcInh8cL845l6s78AboGAEhEMpc2Skrundf/txaHhwe5knICv6zrUrkr5wSiQe16mC1Vd/9IyVgBJ43AQ4QysMl/+WHWKsWecaAqVruLDnn2htPz32yvd/abe0RMuS/DhI8mNgnv+u9g8h/oV2/3GfyxP+veo2AHLwTw7uhPQfwAOD/G764MwWK2AjGYTR9O6vXgnfuvZq2QwB7sUhgJEhxAUcF2fgrhsnoN6AHFh9VgJKQAk8IgLs9SOzn7F4Kcb70evHcu6lyX3cX0JvPr5yzaGxV773rhjw7GJZ+PwRMLe/gTbeQIa/BZ7kJ3/Oc7xQAyAH58TQBtxc34I3IAxvAEzMbOHQALwBtUd/u63uwskfmclkY5k3gMGA6aQ4ly+KjYeTRBCpJg7KEdRnJaAElMDDEUCv3whiGd/1m8XAI7NeS6GZ5pez128Hg+PRLTv/79S+58+UZfdzkN0PtgGGe3+9kNP7zge0GgDFtI71d4oVfk1sowVGgDc4EDMEQte/WNbw0XuvBybG15QZARwSoCEwhADBcyfEGbyn3oBitvpaCSgBJTBfArlef/sSsXp6RZiUjVH//HtRofinGhqvTTz30i8SqzfcKYv0dxDsxyV90/G3ZG9nf9FHq/qlGgCll//0SLOkUt9BNqhVuMu880GDobQ5NRlqOPzOq+H+mwcNBBJ6b0N8mesNSInzuy/gDbggTmw6M0xQ+jv6XgkoASWgBGYnwAj/SA16/Zjb/9SGTDu+jArtAAART0lEQVRasjYLBcyhy7+z64OJA98+ZNfWJySZQE+suGCan+H0SSDwtmxvWXBL+haf6XxfqwEwE7GLTkhi9w9KKr0N4/n0MxV03l1DAEMCxz96uu78qR+Y8Vj7jN4ADgGMjoj9+Vmx+/syFiuzCmpRAkpACSiB2QlwBT94VM3OVWJuQlKf5pZMhP8MvX47HBmMPr3j/03teu48hD/gzekPt4DjWBKwzkhk0Qey2UjM/qPVuUUNgLmu+yeDCDOV53EzhjxxAfwMpgoG7txurv/w3e+GBu/uci3R0u/KCr5zp981BJzhocx0QTUESknpeyWgBKqdAIUfIm+0trnCbyzrzBDh34tKrq1NtC87Prn/5TdTyzpGpXiKH/fleL/jJNB1+608045pWlpmIqAGwExUiv92bBhxAWnMABAMPhWtJsh9OEsA8wbqjn20rfbS2e+aiXhrmTfA3Q/eAAQGOn3XxL7yuTgTY5mhAsYNaFECSkAJVDMBd5wfQX4NTWKu2yTGqjUiCPgrXcGPiNxAv1B4eGrj1jejexHox/n8xVH+Lkes5mcIgrGsQ7K3Vcf757i3VIHmgJPfdMKplfTQQWSN2ozMgTBRi6YKcid6A273tzQcPfxqcOD2XswqRWxAYdTA/Z5ckOD0lDjXr4iNhzM1qYZAHrK+UAJKoKoI5IS/tl7M1evEwENqamcN8kPWFju5uOPYxL4Dh1IdnSPlvX50x0w0tDYW9LHaPpBeY6qqeP4HTlYNgPlA+/TeVgT57Yf815XNEqA3IGDakdOfbag7d+o1ZBBcWWYE8LdyhkB0QpwbV8W+8TtxojAELMQHIDeFFiWgBJTAgibAnGtpTMWvg/B3PyVG91qRuoYZhZ8c3Aj/2vpb0Z4db8W27/5CUrZZ1ut3o/wlihkCH8qeJWcXNL9HeHJqAMwX5onbbWIHXkS+gO5sXIC3qw9vgDk+Hqk7dnhf5Oa1F5E3oGFWQ4CBgpMwBLDAkH0ThgBeZwwENQTme1l0fyWgBHxOIDfGX98gZheEnwv34LXr6qc3oKS47v5gcCLWteb96N4DR+3GxlhZr5/2QWZ+/w0xU+9LbwcCrbQ8KAE1AB6UVPF+v/iFJV0v7oDJ+gwMgZoybwBnCtTUJAN919vrj398MHi3fw/+EpzVEODUQQ4NfHkTawvAEBi5X5g1oHECxeT1tRJQApVEwHXzZ6L6jZZFyN0P4V/RNaurn6fmCr+BqKmlnZ9O7nr2g9Sq1YMyPY1VXDHeX1zY6zdszLM2P5Gb75+S11/3ZgYq3ldfz0jAC3TGXfSPsxI4daddEtYLcN+vdhW7OI0wP8RhgVA4Hb50elXd2RMvBYYHe3BzI0Sg3NrNDw0kEbh677brFWBqYSeJNQY4NKAzB2a9DLpBCSgBnxFwe/tw8weRWBWpe9nbN5Z0ILgvNKerH22jk2ptPxfd2vtefOP2PknErTJ3P9P5ssFM29cllD4iO5YN+uzsK+Zw1AB42EvFBYVOjmyBG+tZeAKacWMyg6BX4cM1KYSvGDXnTq6t/fzsQWtsZMPchgDub1rOyCPg9MMr8NUtccYxc4BjZ/QWqFfgYa+afl4JKIFHTSAb1McOi9GIiP7lK8Xo7MrM42eblR0CKP1Z9vgp/Ommli+mNm39YLpn51Ux4TCNT2OhFU/Bl2Apd8cYRar1j2VnywW3P+XZRd/Mh4AaAPOhNde+Hw02SNjYgwjUHig0M095Uwnzs1hTgAEstedPrI18ce6FwOjIxlkNAe7PXj97/4kYUgsPiPNVHxYcuoPZA9GMieFu10tIVFqUgBJ4AgTyLn40VbWIjV68TIzlq8Rox6zpEJboZaeFwj9DyQl/qrnlUmxDz5Gpp3uvMpC6ZOW+zCfp7mdmVtM4J3HnU3muHQFTWh6WgKrHwxIs/fzRoeUSMvbBbdWNMQDUiqKFhXL7Zg2Bms/PrI5cOvdcYHR4s2k7M8cI8DO0nnNDAFOIFRi6J0wuxPUGMsYAx9hgKOT2yf2OPisBJaAEHjWBrHvf7elT9JGnn0l7jLYlIrWYxscyS2+fmyj8tmkkU82tF2Mbez6a3rTt+hzCj0YUQ/tW4IYknKOyr+0rfoeWR0NADYBHw9H7LRwW+OTOerFCe7BhKbICYFnhktwB/ASHBvh05UJnzedndweH7m3jaoPs3nvHELhXthQbAwwcHBkW5y5iBrAIkTM57iYccvcs3i/3WX1WAkpACcyXQLGYI0GPUd8IsV8sxtIOMVpaMwF9/M7i/Up+IyM0EH6s1pdsW3JmetPWz+LrtmSS9JS7+mklmFiUDb0auSvpxKfyzLLL6u4vgfoI3qoB8AggzvoVJ5CRyh7cjDGrXrGMVgxzzWwIYJEhCQXTgVt9rTWXzjwd6r+1y5qaWJF1kc369QXPAC4jggcFBoAzPAhjAI9RGAYcKuDSxDQnaBCwPvFZixJQAkpgJgJ06dNtz2eoMDPyua795laIfjvS9LZj6h76KAzmY7syh+jz63NtWLq24ctE58rj0xu3nU+tXDUsiaRVvmiP+wEEEKChSjvD8J6eELP9IhL6eBdl4xdreSQEVA0eCcav+ZIPbkSkqX6LpGQ7jAHMhZnFEOCsgUg4JWNjkZqrl7oi17/YEbg/uMlMplDjWN1YKecouZgB7peAQcBkQ2OjGS/B2EjmfSwGjxocD7kKzjvANbT5rLfDHHR1kxJYGATcuo9TcYWep4T2gnXfwqy6CMbtkZTHaMKK6OjdG02Ia2aSnhAFH/vwMxT9OQpFn8UOBsZTi9o/j63ecGp67cab0tQUk1g8UBbVz51zPX7DuS8BOS1jkxfkYDcaKy3fJAFt8b9JuqXfTUOgsX6zpJxtGLBvw2akFZ4hRsBdcTCQxpi+E7hztzly5dz60Fdf9gTGR9cY6XQNv/ZrjQG3x4/L64o6nrmMZgJTCuEVcBMOTcBbQI8BvQQYSqAHwUnBMEhjP7cXwEYhdwLZF+5T/o+5jfqsBJSAbwig3uL/TMm+4FOuPUDyMSOAeDr24JF21+3ds0ffALc+k/JgTB9Tl9E8YeidX5RrC3JGQ/abS59you9Y1nSqsflaYvmKc7F1PZdTy5aOwmDArP6U5T6XfpBJfNyWxh6SgHFGxicvqvCXQvrm3mtr/s2xnf2budzw9Mh6SSW3IYfAUnesK2MI5Ktu/sNuLgEYA5g9EOjva43cuLI2dOfLzdbEeLeZSiIChyteln8s//niF7lGIGcUsIJT8Cn8NA7oNYhPixPH6ziMbzw7HFrgg14DpO90DYlcD8D93Qf87eLj0NdKQAk8IgJowt36jK+jB5DCzbTi6M1T5A0KfRiCHo6I4T6j/8DePEWehgCzkbqWPurxA4p97sAN/i4+YweC0XRD443EshUXY93rrqY64eJnNH8Col+2UI/76Uz2PnpC0/ZdCQTPSE3LZV2uN0f28T2rAfD4WJf/EjMKdr+AOTNWDypSFx6opUYaujyzjy03RIDkGIG7d5vDN3/XFbr75frA2Ei3EY+1cxEi/sjXegdKjyTXgPDZfV18W2QF3tM4sLEo/RJ9rwSUwBMj4FbZbP3N12MeTUldztVjbuLreZR8L5/L7YQjg6mmlhuJpSsux7ueuplaip4+kp7N6uLn79DN7zhwQRgxPG6Kkz4nN470aQa/eVyER7xr8d3xiL9av25eBH6LrIIRayNqyXpUjhaYAKhv7vDAzLU05xnAj5ij4zXB231LQv03uxEz0B2YmOg0kvFmGASobNjB1euZv2Zex6g7KwElUBUEXLHPtR3IuecEw6OphoZ+jOnfSHR23Uh2rLpnNzciDS/K7D19bs329tkvcRCI5FyWWPqSPK/Z+wjnSRc1AJ70FSj9/atOWO4NdUnQhjFgrYCE17pdes4gcKW89AN4z5gBGgSBYBoZB01zbLQ2eOd2a3Cgf3lweHiFNTneYcSn24xksh4VO2PIu/bAvH0FM/y4/kkJKIFKJZARAPybE3uotBMMTjrhmqF0fePtZGvrl8nFnV8ll3UM203NU8jQZ2PoMuPaL83NX4DAZgbR/PgvLQgwSn8pSfOSLGm7KWsNjC9q8QsBNQD8ciVmOo4T95skmV4jloP1Mi3mE4i44/AcJpjNGOD35AwCE+NwLMlEwBwdrgsODSyCh6AtMDq62IyOLzFjsWYjEW8yUykYGTYGBtEOuEMAfJUteceBGgs5JPqsBPxMIC/qPMiSFj4fL2SYCTsQmHJC4TE7Ehm16xrvpZqbB9DDH0q2Lb5vN7dGEUOAwB8UO7v87uyCz70YjGS58Qc2XPySxvx946oErWvSuwh5zLX4kUDJ7eHHQ9RjcglcHFsk04kuOOPW4P1SPGrdyjZbboFSbDmjgME5sCjoKWDKTTM6EQmMj9UZk+N1gfHxJnN6ssGIxeqsRKwBQYG1RjoVMdPpMIIFgzASgobtBGAKoLKzacGzFiWgBJ4wAQz20dGOMUPHxFokhplEcF/Stqy4YwViCPqbSociE04kErVr6idSjY1jTn1jNNXYFLXrGmJuinL27KHYDDZ2A/fmFvvM+XJM352z7/Yz0NNH0h7LuCY1oZuyuen+E4aiP/8ABLQBfwBIvtvl2DDm7SQ6Ucm7IObLIMyYrIukQw6GAjhRF0E6D3zMNAwMPAJoAExGBcE4cAsaAxY2CMmEhZkC2BPTefiexcBrm4ZAyRKd7kb9RwkogcdCgHXX5AKjrPsoMPCRQA/1GUOCTDDmGvzcUFSvbbj5UugAsO4+iNDz4yxukDFd+6zzSM5jmKMwGu6gc3AT0wr6ZW8rUpFqqSQCagBU0tWa6ViZbVCG2jDWthwNwXK44RajomJCLxckQkV10OM35ogfmOk7Z/obDQUtSkAJVAaB+Qj7zGdEnwLFHoYC6z4W4jFkAj3+ARj+XyE2CTn524Y0S9/M8Crlr2oAVMqVetDjZI6BiQHMIoAhEAwix4CN/J1GEyowxvmxohYDczLD+ajU6Uzvn7a9FiWgBKqNQNaDZ1EH2DJk2gZ3JVMDC404Y4gnGkQ68bvoXAxIw+IRnau/sG4RNQAW1vWc+WxO3K5Fto5GJPFZhJwDrajMLQgmbEIMAYwCE7k/bQwfcH6uifshO3pAqx+2v5v4h71//pnNgxYloAT8TYARARyooxeAiYHcKcV027Ngg2NjDwYSI1bAsGNoC6bQFoyh0zCCufnD+Mx9MVPj0tvBcX0tC5iAGgAL+OLOeWpcsfDwzbCEA7ViYg3PgFMPhwAeUodxwxoYBHyE0UBgdgCGE0yk7ESUgBv0w55CxsWo98+ckHWjEngsBGCsw0h3/8NwH9bRg5gzp3cSBn4CdTaOB+bsm+jVpyD2xqSk8LCxtngc7w90cbsa94/lUvnrR7QB99f18N/R/Nwx5YXDpiw+YMpYvyV1naZMDJkSGMW9s8h/x6tHpASqjgAC7lPNiPxpsyXab0tTZ1oGDtty5IAtPzcePCC46rjpCSsBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAJKQAkoASWgBJSAElACSkAJKAEloASUgBJQAkpACSgBJaAElIASUAK+IvD/AWxantH6SFK5AAAAAElFTkSuQmCCaWMwNQAACSRBUkdCpQAAB4sJAAeKAAMJR5K5i8EDuZJHCYYAAiKv/Y//Av2vIoQAASLSk/8B0iKCAAEJsZX/AbEJgQABRv2V/wH9RoAAAQGTl/8FkwEAAAe6l/8FugcAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAnBl/8FwQkAAAe6l/8FugcAAAGTl/8BkwGAAAFG/ZX/Af1GgQABCbGV/wGxCYIAASLSk/8B0iKEAAIir/2P/wL9ryKGAAMJR5K5i8EDuZJHCYoAAAeLCQAHpQDDAAELEI0RARALhwACCBASjxMCEhAIhAACCBETkRICExEIgwABEBOGEoEThhIBExCCAAALhBKAEwURCAcHCBGAE4QSAAuBAAEQE4MSAwoHBwSBAAMEBwcKgxIBExCBAAEQE4ISAQcDgAmBCoAJAQMHghIBExCBAAERE4ESAhACD4cTAg8CEIESARMRgQABEROBEgIQAhCHEgIQAhCBEgETEYEAARETgRICEAIQhxICEAIQgRIBExGBAAERE4ESAhACEIcSAhACEIESARMRgQABEROBEgIQAhCHEgIQAhCBEgETEYEAARETgRICEAIQhxICEAIQgRIBExGBAAERE4ESAxACEAiFBAMIEAIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAERE4ESAxACDQGFAAMBDQIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAERE4ESAxACDwKFAAMCDwIQgRIBExGBAAEQE4ESAxACEAOFAAMDEAIQgRIBExCBAAEQE4ESAxECDw+FDAMPDwIRgRIBExCBAAALghICEwgChwcCAggTghIAC4IAARATghIADIcJAAyCEgETEIMAAggRE4ESiROBEgITEQiEAAIIEBKPEwISEAiHAAELEI0RARALwwClAADbi+MA24oAA+Oaa1eLUgNXa5rjhgAEy2IwHBeLFgQXHDBiy4QAA8NTGxSPFwMUG1PDggAD42EbFoQXABWBDwAVhBcDFhth44EAApkwFIEXDRYPDwwkipOTiiQMDw8WgRcCFDCZgAAC/2ocgRcPFR1ympaw8vDw8rCWmnIdFYEXBhxq/wAA21WCFwUUl79+f32BdwV9f36/lxSCFwZV2wAA41IWgBcEFCvNNQqFDgQKNc0rFIAXBxZS4wAA41IWgBcEFDHIKxSFFwQUK8gxFIAXBxZS4wAA41IWgBcEFDDILBSFFwQULMgwFIAXBxZS4wAA41IWgBcEFDDI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AAECBDogIAHQgUpWRAIECBAgQIAAAQIECBAgIAFgGyBAgAABAgQIECBAgAABAh0QkADoQCUrIgECBAgQIECAAAECBAgQkACwDRAgQIAAAQIECBAgQIAAgQ4ISAB0oJIVkQABAgQIECBAgAABAgQISADYBggQIECAAAECBAgQIECAQAcEJAA6UMmKSIAAAQIECBAgQIAAAQIEJABsAwQIECBAgAABAgQIECBAoAMCEgAdqGRFJECAAAECBAgQIECAAAECEgC2AQIECBAgQIAAAQIECBAg0AEBCYAOVLIiEiBAgAABAgQIECBAgAABCQDbAAECBAgQIECAAAECBAgQ6ICABEAHKlkRCRAgQIAAAQIECBAgQICABIBtgAABAgQIECBAgAABAgQIdEBAAqADlayIBAgQIECAAAECBAgQIEBAAsA2QIAAAQIECBAgQIAAAQIEOiAgAdCBSlZEAgQIECBAgAABAgQIECAgAWAbIECAAAECBAgQIECAAAECHRCQAOhAJSsiAQIECBAgQIAAAQIECBCQALANECBAgAABAgQIECBAgACBDghIAHSgkhWRAAECBAgQIECAAAECBAhIANgGCBAgQIAAAQIECBAgQIBABwQkADpQyYpIgAABAgQIECBAgAABAgQkAGwDBAgQIECAAAECBAgQIECgAwISAB2oZEUkQIAAAQIECBAgQIAAAQISALYBAgQIECBAgAABAgQIECDQAQEJgA5UsiISIECAAAECBAgQIECAAAEJANsAAQIECBAgQIAAAQIECBDogIAEQAcqWREJECBAgAABAgQIECBAgIAEgG2AAAECBAgQIECAAAECBAh0QEACoAOVrIgECBAgQIAAAQIECBAgQEACwDZAgAABAgQIECBAgAABAgQ6ICAB0IFKVkQCBAgQIECAAAECBAgQICABYBsgQIAAAQIECBAgQIAAAQIdEJAA6EAlKyIBAgQIECBAgAABAgQIEJAAsA0QIECAAAECBAgQIECAAIEOCEgAdKCSFZEAAQIECBAgQIAAAQIECEgA2AYIECBAgAABAgQIECBAgEAHBCQAOlDJikiAAAECBAgQIECAAAECBCQAbAMECBAgQIAAAQIECBAgQKADAhIAHahkRSRAgAABAgQIECBAgAABAhIAtgECBAgQIECAAAECBAgQINABAQmADlSyIhIgQIAAAQIECBAgQIAAAQkA2wABAgQIECBAgAABAgQIEOiAgARABypZEQkQIECAAAECBAgQIECAgASAbYAAAQIECBAgQIAAAQIECHRAQAKgA5WsiAQIECBAgAABAgQIECBAQALANkCAAAECBAgQIECAAAECBDogIAHQgUpWRAIECBAgQIAAAQIECBAgIAFgGyBAgAABAgQIECBAgAABAh0QkADoQCUrIgECBAgQIECAAAECBAgQkACwDRAgQIAAAQIECBAgQIAAgQ4ISAB0oJIVkQABAgQIECBAgAABAgQISADYBggQIECAAAECBAgQIECAQAcEJAA6UMmKSIAAAQIECBAgQIAAAQIEJABsAwQIECBAgAABAgQIECBAoAMCEgAdqGRFJECAAAECBAgQIECAAAECEgC2AQIECBAgQIAAAQIECBAg0AEBCYAOVLIiEiBAgAABAgQIECBAgAABCQDbAAECBAgQIECAAAECBAgQ6ICABEAHKlkRCRAgQIAAAQIECBAgQICABIBtgAABAgQIECBAgAABAgQIdEBAAqADlayIBAgQIECAAAECBAgQIEBAAsA2QIAAAQIECBAgQIAAAQIEOiAgAdCBSlZEAgQIECBAgAABAgQIECAgAWAbIECAAAECBAgQIECAAAECHRCQAOhAJSsiAQIECBAgQIAAAQIECBCQALANECBAgAABAgQIECBAgACBDghIAHSgkhWRAAECBAgQIECAAAECBAhIANgGCBAgQIAAAQIECBAgQIBABwQkADpQyYpIgAABAgQIECBAgAABAgQkAGwDBAgQIECAAAECBAgQIECgAwISAB2oZEUkQIAAAQIECBAgQIAAAQISALYBAgQIECBAgAABAgQIECDQAQEJgA5UsiISIECAAAECBAgQIECAAAEJANsAAQIECBAgQIAAAQIECBDogIAEQAcqWREJECBAgAABAgQIECBAgIAEgG2AAAECBAgQIECAAAECBAh0QEACoAOVrIgECBAgQIAAAQIECBAgQEACwDZAgAABAgQIECBAgAABAgQ6ICAB0IFKVkQCBAgQIECAAAECBAgQICABYBsgQIAAAQIECBAgQIAAAQIdEJAA6EAlKyIBAgQIECBAgAABAgQIEJAAsA0QIECAAAECBAgQIECAAIEOCEgAdKCSFZEAAQIECBAgQIAAAQIECEgA2AYIECBAgAABAgQIECBAgEAHBCQAOlDJikiAAAECBAgQIECAAAECBCQAbAMECBAgQIAAAQIECBAgQKADAhIAHahkRSRAgAABAgQIECBAgAABAhIAtgECBAgQIECAAAECBAgQINABAQmADlSyIhIgQIAAAQIECBAgQIAAAQkA2wABAgQIECBAgAABAgQIEOiAgARABypZEQkQIECAAAECBAgQIECAgASAbYAAAQIECBAgQIAAAQIECHRAQAKgA5WsiAQIECBAgAABAgQIECBAQALANkCAAAECBAgQIECAAAECBDogIAHQgUpWRAIECBAgQIAAAQIECBAgIAFgGyBAgAABAgQIECBAgAABAh0QkADoQCUrIgECBAgQIECAAAECBAgQkACwDRAgQIAAAQIECBAgQIAAgQ4ISAB0oJIVkQABAgQIECBAgAABAgQISADYBggQIECAAAECBAgQIECAQAcEJAA6UMmKSIAAAQIECBAgQIAAAQIEJABsAwQIECBAgAABAgQIECBAoAMCEgAdqGRFJECAAAECBAgQIECAAAECEgC2AQIECBAgQIAAAQIECBAg0AEBCYAOVLIiEiBAgAABAgQIECBAgAABCQDbAAECBAgQIECAAAECBAgQ6ICABEAHKlkRCRAgQIAAAQIECBAgQICABIBtgAABAgQIECBAgAABAgQIdEBAAqADlayIBAgQIECAAAECBAgQIEBAAsA2QIAAAQIECBAgQIAAAQIEOiAgAdCBSlZEAgQIECBAgAABAgQIECAgAWAbIECAAAECBAgQIECAAAECHRCQAOhAJSsiAQIECBAgQIAAAQIECBCQALANECBAgAABAgQIECBAgACBDghIAHSgkhWRAAECBAgQIECAAAECBAhIANgGCBAgQIAAAQIECBAgQIBABwQkADpQyYpIgAABAgQIECBAgAABAgQkAGwDBAgQIECAAAECBAgQIECgAwISAB2oZEUkQIAAAQIECBAgQIAAAQISALYBAgQIECBAgAABAgQIECDQAQEJgA5UsiISIECAAAECBAgQIECAAAEJANsAAQIECBAgQIAAAQIECBDogIAEQAcqWREJECBAgAABAgQIECBAgIAEgG2AAAECBAgQIECAAAECBAh0QEACoAOVrIgECBAgQIAAAQIECBAgQEACwDZAgAABAgQIECBAgAABAgQ6ICAB0IFKVkQCBAgQIECAAAECBAgQICABYBsgQIAAAQIECBAgQIAAAQIdEJAA6EAlKyIBAgQIECBAgAABAgQIEJAAsA0QIECAAAECBAgQIECAAIEOCEgAdKCSFZEAAQIECBAgQIAAAQIECEgA2AYIECBAgAABAgQIECBAgEAHBCQAOlDJikiAAAECBAgQIECAAAECBCQAbAMECBAgQIAAAQIECBAgQKADAhIAHahkRSRAgAABAgQIECBAgAABAhIAtgECBAgQIECAAAECBAgQINABAQmADlSyIhIgQIAAAQIECBAgQIAAAQkA2wABAgQIECBAgAABAgQIEOiAgARABypZEQkQIECAAAECBAgQIECAgASAbYAAAQIECBAgQIAAAQIECHRAQAKgA5WsiAQIECBAgAABAgQIECBAQALANkCAAAECBAgQIECAAAECBDogIAHQgUpWRAIECBAgQIAAAQIECBAgIAFgGyBAgAABAgQIECBAgAABAh0QkADoQCUrIgECBAgQIECAAAECBAgQkACwDRAgQIAAAQIECBAgQIAAgQ4ISAB0oJIVkQABAgQIECBAgAABAgQISADYBggQIECAAAECBAgQIECAQAcEJAA6UMmKSIAAAQIECBAgQIAAAQIEJABsAwQIECBAgAABAgQIECBAoAMCEgAdqGRFJECAAAECBAgQIECAAAECEgC2AQIECBAgQIAAAQIECBAg0AGBzQ6UUREJECDQHYHh8KSsg3jO1/lcTfXz6E9PBAgQuEOgd/JOP5578cjnnPK1iQABAgRaISAB0IpqVAgCBDorUAf5h0dxjN4rvZ3tMry0Vcq1+8rGQ1dLue9yKdubpVcfyHcWSsEJEJgmMMyE4cFRKTf2yvHDj5Vy/Ubp7R+W4e5B5BPjs604bKyTA9Nm5nMCBAgQaKSABEAjq8VKESBAYIrA8aCUCPr7l7dL+bAnlfJxzy4HL/iI0v/oZ5SDZz+t7D14tfS2NkrZiCu9quDfGbwpoj4mQKBEkJ9JgGhfhofH5fIHHyvbv/5bZfBL7yjbb3lbKf/110t51/vLYO/gJBmQ7YuJAAECBNZKQAJgrarLyhIg0HmBDPoDofdhH1KOX/lx5eAzP7Hc+ITnlOEDV8sgzvSX4+Pq4L3q/h/H8SYCBAicSyDyhiU6EZWdUm4+cKXcfPZTS3nVJ5V+9AzoPfJYue+//FrZ/Lc/VzZe/1/L8O3vLZGKPEkG5LOJAAECBBovIAHQ+CqyggQIEAiBo+OS5/D7v+1Z5eC1ryx7n/3icvDUh/J8XdUToAr8b0bwbyJAgMDcBKKFOcoQ/6gMsgG6/0q5/js/ofTisf3uh8vlH/rPZfufvb4MfuFtJ23RZmYPTAQIECDQZAEJgCbXjnUjQIBAdMft5Vn/50XX/j/02eXm57y0HD5w38l1unFtrokAAQJLEchsY44DkGMCxMv9J14r+3/gVWXrC19ervzLN5bt7/qhMvjld5RhPU7AUlbKQggQIEDgvAISAOcV830CBAgsSyAC/40YxG/wh15drv+R15T9pzwUgX8E/Xn9rYkAAQKrFBhEz4Boiw5j4NFHft9nlEuf9aJy9W/967Lxj/9dOY5BBKsBA1e5fpZNgAABAncVkAC4K4s3CRAgsGKBOMu28fwPL7vf9CXlxqe9sAzjEgCB/4rrxOIJELhTIAcNjETA/hPuLwff9HvLfdFe7fz5f1KOf/E3Ssk7kpgIECBAoFECEgCNqg4rQ4BA5wWii20vRt/uveaTy6N/7svK3tOeEAfXh9X1/523AUCAQHMFYqyAYTwee8ULy9E/eka5+mf+QRn+m5+JSwJiXIC4RamJAAECBJoh4P4tzagHa0GAAIHq9lv9vL1fXOv/8Hf+72XvyQ9W9+B26GzjIEBgHQSyrepF76Vsu7INy7asatOyl4CJAAECBBohoAdAI6rBShAg0HmBHOxvGGfQ/tjnlw++7gvKcR4vR7d/h82d3zIAEFg/gWi7jjc3ywe/8UvKg1d3Su+v/0AZDuKcU186c/0q0xoTINA2AQmAttWo8hAgsH4CEeX3juMa/6/8nPLBr43gP5MBzpitXz1aYwIEHheIQQKPI+DPNu3Bo6PS+xv/sgx7cdgpB/C4kVcECBBYgYAEwArQLZIAAQLjAr0Y2b/3e35Hefhr/9dynKf+I/h35n9cyGsCBNZSINqzbNI+GG3bQ+9/tJTv+fEyNDDgWlallSZAoD0CxgBoT10qCQEC6ygQ18v2X/6C8sj/+Xurs2UZ/JsIECDQGoFo07InQLZx2daVaPNMBAgQILA6AQmA1dlbMgECXReIEbM3nv7EciNG+z+8f6dE3/+uiyg/AQJtFIi2Ldu4bOuyzSvR9pkIECBAYDUCEgCrcbdUAgS6LhAn+nM8rIPXfWG5+TEfXsrhUddFlJ8AgTYLRBuXbV22edVYgDo7tbm2lY0AgQYLGAOgwZVj1QgQaLFAXPdfXvVJ5bEv+O2l7MVrB8MtrmxFI0CgEoi2Ltu8h37s50r5kZ8txXgANgwCBAgsXUAPgKWTWyABAp0XiGtiNx68r9z8o59Xjre3IvgX/Xd+mwBAoAsC0dZlm5dtX7aBxjzpQqUrIwECTRPQA6BpNWJ9CBBov0B0hR285pVl9+M/Kq4ByK7/7ovV/kpXQgIEKoGD46rt23nNS0v5xz+mF4DNggABAksWkABYMrjFESDQcYE4+99/6Gq58Xs/swxzxH9n/zu+QSg+ga4JxG1Oo+27GW3gff/mp8rgsb2TAVG6xqC8BAgQWJGASwBWBG+xBAh0U6AXZ/+Hr/i4sv/Rz4yRsA38182tQKkJdFwg2r5sA7MtzDbRRIAAAQLLE5AAWJ61JREgQKD0tjfL4ee+rAz60fy69N8WQYBAFwWi7cs2MNvCbBNNBAgQILA8AQmA5VlbEgECXRc4PC79Zz+t3Pyk5zr73/VtQfkJdF0gegHcfNFzqzaxRNtoIkCAAIHlCEi7LsfZUggQIFB6x4Ny+MnPL8cP3l/Kftz6z0SAAIGuChzHHQEeur9qE/v//e1luLXRVQnlJkCAwFIF9ABYKreFESDQaYHo6jp46QuM+9fpjUDhCRCoBXIM1GwTi8sAahLPBAgQWLiABMDCiS2AAAECIRCjXvceuFJufuyzSjnW3dU2QYAAgWwLs03MtjHbSBMBAgQILF7AJQCLN7YEAgQIVEF//1lPK8Ps/l/d/g8KAQIEOi4QbWG2idk2Dt70K3E7QIelHd8iFJ8AgSUI6AGwBGSLIECAQJ7pOvywp5TB1cuRAOBBgAABAtkWZpuYbaOeUbYHAgQILEdAAmA5zpZCgEDHBXq9Xjl++hPLYDMHutLVteObg+ITIFAJDKs2MdvGbCNNBAgQILB4AQmAxRtbAgECBEpvY6NsPOUJrnO1LRAgQGBcIC4DyLYx20gTAQIECCxewMVWize2BAIECJSy0T+5/j9ufaUDgA2CAAECI4FoE6uxUaKNNBEgQIDA4gW0tos3tgQCBLoukD3+s3vrzna80P2/65uD8hMgMC4QbWK2jdlGah7HYbwmQIDAQgQkABbCaqYECBC4U2C4qdPVnSreIUCg6wLaxq5vAcpPgMAyBRyNLlPbsggQ6K5Ajm+Vj7wDgLNc3d0OlJwAgVsFsk2s20dt4602/iJAgMACBPQAWACqWRIgQIAAAQIECBAgQIAAgaYJ6AHQtBqxPgQItFIgT2zlSa6c6ueTv/yfAAEC3RWo20Yn/7u7DSg5AQLLFZAAWK63pREg0FGBXhzdDkdHuA50O7oRKDYBAncVyLaxaiPv+qk3CRAgQGCeAhIA89Q0LwIECEwTyOhfBmCaks8JEOiKgPawKzWtnAQINETAGAANqQirQYAAAQIECBAgQIAAAQIEFikgAbBIXfMmQIDASMBJLpsCAQIEzhbQRp5t4xMCBAjMU0ACYJ6a5kWAAAECBAgQIECAAAECBBoqYAyAhlaM1SJAoIUCeYqrfrSweIpEgACBcwtoE89N5gcECBC4FwE9AO5Fz28JECAwo4Bb/80I5WsECHRSQBvZyWpXaAIEViCgB8AK0C2SAIHuCYxf3+pAt3v1r8QECNxdoG4b6+e7f8u7BAgQIDAvAQmAeUmaDwECBCYIPB709+IqgMf/mvATHxEgQKADAiftYf5fEqAD1a2IBAisXEACYOVVYAUIEOiCwLCO+fMI11FuF6pcGQkQmEVg1B5WbaS2cRYx3yFAgMA9CRgD4J74/JgAAQIECBAgQIAAAQIECKyHgB4A61FP1pIAgXUXGDvzX3cGWPciWX8CBAjcq0B10n+sfbzX+fk9AQIECEwWkACY7ONTAgQIzF1AL9e5k5ohAQIECBAgQIDADAISADMg+QoBAgTmJuBM19wozYgAgRYIyIi2oBIVgQCBdRIwBsA61ZZ1JUCAAAECBAgQIECAAAECFxTQA+CCcH5GgACBcwvUZ/+d8To3nR8QINBSgbpdbGnxFIsAAQJNE9ADoGk1Yn0IECBAgAABAgQIECBAgMACBCQAFoBqlgQIECBAgAABAgQIECBAoGkCEgBNqxHrQ4AAAQIECBAgQIAAAQIEFiBgDIAFoJolAQIE7ipQX+tqDIC78niTAIEOCtTtYgeLrsgECBBYhYAeAKtQt0wCBAgQIECAAAECBAgQILBkAQmAJYNbHAECBAgQIECAAAECBAgQWIWABMAq1C2TAAECBAgQIECAAAECBAgsWcAYAEsGtzgCBDosUF/ragyADm8Eik6AwC0Cdbt4y5v+IECAAIFFCegBsChZ8yVAgAABAgQIECBAgAABAg0SkABoUGVYFQIECBAgQIAAAQIECBAgsCgBCYBFyZovAQIECBAgQIAAAQIECBBokIAxABpUGVaFAIEOCLjetQOVrIgECMwsYEyUmal8kQABAvMQ0ANgHormQYAAAQIECBAgQIAAAQIEGi4gAdDwCrJ6BAgQIECAAAECBAgQIEBgHgISAPNQNA8CBAgQIECAAAECBAgQINBwAWMANLyCrB4BAi0SqK//d81riypVUQgQuCeBul28p5n4MQECBAjMKiABMKuU7xEgQGBOAr05zcdsCBAgsO4C8qHrXoPWnwCBdRNwCcC61Zj1JUCAAAECBAgQIECAAAECFxDQA+ACaH5CgACBCwmMuroOnfK6EJ8fESDQQgGXALSwUhWJAIEmC+gB0OTasW4ECBAgQIAAAQIECBAgQGBOAnoAzAnSbAgQIDBdIK/+rx/Tv+0bBAgQaL+ANrH9dayEBAg0SUAPgCbVhnUhQIAAAQIECBAgQIAAAQILEtADYEGwZkuAAIE7BOprXY0BcAeNNwgQ6KhA3S52tPiKTYAAgWUL6AGwbHHLI0CAAAECBAgQIECAAAECKxDQA2AF6BZJgEC3BfKKVxMBAgQIlKJDlK2AAAECyxWQAFiut6URINB1gTjadRvArm8Eyk+AwKmADMAphRcECBBYhoBLAJahbBkECBAgQIAAAQIECBAgQGDFAhIAK64AiydAgAABAgQIECBAgAABAssQkABYhrJlECBAgAABAgQIECBAgACBFQsYA2DFFWDxBAh0SKC+3ZVrXjtU6YpKgMBEgbpdnPglHxIgQIDAvAT0AJiXpPkQIECAAAECBAgQIECAAIEGC0gANLhyrBoBAgQIECBAgAABAgQIEJiXgATAvCTNhwABAgQIECBAgAABAgQINFjAGAANrhyrRoBAywTqa12NAdCyilUcAgQuLFC3ixeegR8SIECAwHkE9AA4j5bvEiBAgAABAgQIECBAgACBNRWQAFjTirPaBAgQIECAAAECBAgQIEDgPAISAOfR8l0CBAgQIECAAAECBAgQILCmAsYAWNOKs9oECKypgOtd17TirDYBAgsRMCbKQljNlAABAmcJ6AFwloz3CRAgMG8BB7rzFjU/AgTaIKBtbEMtKgMBAmsiIAGwJhVlNQkQIECAAAECBAgQIECAwL0ISADci57fEiBAgAABAgQIECBAgACBNREwBsCaVJTVJECgJQLGAGhJRSoGAQJzEdD9fy6MZkKAAIFZBfQAmFXK9wgQIECAAAECBAgQIECAwBoLSACsceVZdQIE1kzAma41qzCrS4DAUgS0jUththACBAikgEsAbAcECBBYpoBLAJapbVkECDRdQPDf9BqyfgQItExAD4CWVajiECBAgAABAgQIECBAgACBuwlIANxNxXsECBAgQIAAAQIECBAgQKBlAi4BaFmFKg4BAk0W6MXK1Y8mr6d1I0CAwLIEtInLkrYcAgQIpIAEgO2AAAECyxQwBsAytS2LAIGmCxgDoOk1ZP0IEGiZgEsAWlahikOAQIMFHOg2uHKsGgECKxPQNq6M3oIJEOiegB4A3atzJSZAYMUC2eHVRIAAAQKliP1tBQQIEFiugATAcr0tjQCBrgvE0e7QEW/XtwLlJ0CgFtAe1hKeCRAgsBQBlwAshdlCCBAgQIAAAQIECBAgQIDAagUkAFbrb+kECBAgQIAAAQIECBAgQGApAhIAS2G2EAIECISArq42AwIECNwpoG2808Q7BAgQWJCAMQAWBGu2BAgQuKtAHug62L0rjTcJEOiggPawg5WuyAQIrFJAD4BV6ls2AQIECBAgQIAAAQIECBBYkoAEwJKgLYYAAQIECBAgQIAAAQIECKxSwCUAq9S3bAIEuiVQd//X5bVb9a60BAicLVC3i2d/wycECBAgMEcBPQDmiGlWBAgQuKtA767vepMAAQIExgW0leMaXhMgQGAhAnoALITVTAkQIHC2gGPcs218QoBAtwR0iOpWfSstAQKrF9ADYPV1YA0IECBAgAABAgQIECBAgMDCBfQAWDixBRAgQGBMIE53DTtxymsZhdSXYmzL8pLAegoso6lYTxlrTYAAgYUISAAshNVMCRAgcKfA+h7njta8erq9FBGE9zIQr5+z3PXf+XJj7LPodHbX7+ZvxqdYRpUlyWWNXg8Ho9f1c35/9Hn1ndHfp7/Lv8enXL/679MX9RueCRBYoUD+SzYRIECAwHIEJACW42wpBAgQOIlXG+mQQXau2NhheC+D9bxKLAPneO7H7qK/dfLo5XME9r14r/4sA/3q+6PfVX9noF0H2zmfXEY93fJH/ebY89i6nL6sX0QSIAP9TApUiYHjUgaZGIjHIF4PR4/B0eh1PA8O45F/5yPnM/p99VzPNxc/vp7T1jG/byJA4J4Fxv8J3vPMzIAAAQIEJglIAEzS8RkBAgRaIzA6wq6C3yxUBrp1sB67go1L8diOwD4e1fMo2M/APwP9kt/NgLgOkG8PjjOgzvmOT3e8Mf7hlNdj8z99Wb+o12VsFtW6jf1dvazXKdcjX4+e60RAJgsyMZBJgSpBEK+PD+J1PKpEwSjRkImFW9zq5dTrU//tmQABAgQIECDQbAEJgGbXj7UjQKBFAlW4OIpBF1usXEhMGbRmYFwF+hnkR3C/uROx/OVbA/48s18F0LcF1qdB72h+JzON+VYzr/5a3f/G1ynW4nRdz1qjdBgF7BujXV/9d/2Tah6jYD97FtRJgeo5kgJ1cuB4f5Q4yO/GIxMEp9NoGbd2dzj91AsCBG4TyGbqtrf8SYAAAQKLE5AAWJytORMgQGAJAnH0XAfkVbA/6pq/eSWC/Xzkmf1RwF932T8NfMd+W61p/l3NbAnrvcpFjMp417KOEgV5CUOVGMn1HIUn1fdHRnmZQfYUyEcmBqpHJAaOd29NDlQJgtE8qtkIdVZZ85ZNgAABAgS6LiAB0PUtQPkJEFiawHxC61EAmmtdB6kZ6G/dF4F+nN3frIP9+pr8/GL+ZvRcvZ7PmuQc2zuNjE7dxkpaJVrq8RCuPv5BBvuZJKiTA9lToEoM7MVzPI7iUY9PIDHwuJtXnRfQInV+EwBAgMASBSQAlohtUQQIEDi/QAaUo8PjHHivH2f0tyLo3MxHBvzZpT+a8moAvph7fZY6F3QaZJ5/qX4xTWBUJ3Xd1F8fTw5kPeVU10nWR15OUCUGMjmQSYHoMZDPpwMW1pcTZE+E/LEeA6lgIkCAAAECBOYjIAEwH0dzIUCAwHSBjBnrx5nfji9UsWX8bzzg386AP87yZ8BfD943fjZfsH+m6PI/qCpwFPiPLT3rLS/HyDqspqzrfIwnBkY9BTIxUPUYyLsW5F0NRvM8vXxDYmBM1st1FshNe7R5r3MxrDsBAgTWRUACYF1qynoSINBigQwC41GdPY5mOYP97Wsnz9m9//SWeqPvpYSAf023h7E6rEtwe2LgtMdABP55CUEmAureAlWPgXivvpSgmofeAjWlZwIECBAgQGCygATAZB+fEiBAYDECdZBXBX9xRrgK+O8/6d6fo/Xn+6dn+O8SNC5mrcx1ZQJ3qeNM/NTjO+R6ZdInt5u8RWGVCIjLCPL58OZJgqAaeyCSBvXp1Kq3gJ4CK6tSCyZAgAABAg0UkABoYKVYJQIEWiiQgdsgu3rnNd4RlGVgd/nBk8A/B/Crz/LXiQFn+Fu4EVykSLclBqpeIpEguhSP3I6q7WW0XVVjC4wuHcikQCYHbh9bwCUEF6kEv1mkQGzidc5qkYsxbwIECBA4EZAAsCUQIEBgUQIZnB0fl95RnLG9dq0Mrj6hlPufGdf2j67lz2v8c6qC/dsCvZNP/J/AXQRyW8m3q//FcyQCclvaiO2q1AMPRlIgt6vTSwiyp0AmB7K3QH0JQXyek6TAiYP/L1lgtB3Hdto7Piq9/b0yrHpE5WCn0QPqdLtc8mpZHAECBFouIAHQ8gpWPAIEViAQZ/l7hzHa+0507f/I55a9l39aOfrkTy37L3pRnPWPQeAycMvkgLP8K6icFi+y7j1SFzGDqRxwcCt6m+SU21t+J+9EkL0DcmyB6jmTAnE5wSAHG8xLCHKKpEL8N/pfvjARmIPAqO2rklZxCLod2+alK2X32S8sgy/+srL9vveU4a/9aun91rtK2d0tw6283WZeDmUiQIAAgXkJSADMS9J8CBAgEAK9gzi7ev/95eh3f37Z/6zPLvvPe34Z3hdnZTP4ygNZQb/tZKkCdcA1WmieVd2IW0luZiIqpjoRlZcKVAMNjpIChzdOkgK3jCsgKXCC5v/nFqiSU/GrfgT0l6I9vBy9obZjzJNqvJNeOXjeh5WDr35B1ROg7O2WS7/yy+XSv/2hsvljP1zKY49GIiAveTERIECAwDwEJADmoWgeBAgQiLP6vYPDMnjRS8qNr/yacvD8jw2TCJiO4mzrQZxdzWknAq+Ix0wEVitwW1KgOhsbAVYGY9sPnCQFSiSsskdA9gwY7ymQr0/HFRhtzKddtasuA6stmqU3RKDexjLhlGf64/KUyw/Fc9zdJG+FmdtMlXwafS+3tWgroxWN7+2UvRe9uOx94ieV7dd8XrnyN/9a2fi5nz7pDZCfmwgQIEDgngQkAO6Jz48JECBwItA7PCrHv/vzyvWv+RNxrX+c2cqeACYCayOQgViubPW/eI5Aqx+HCBtxxjbP1Ob7VcCWSYHYtutbE56OKxCJrurWhKNxBfL3VawmYEvVbkyjbSSD+zzTn9vNpUgoVWf6I/mZl6RUPQFG37srSn4WH4zaz4OPfWE5+o6/Uq79le8oG//mX4ySAHf9oTcJECBAYEYBCYAZoXyNAAECZwrEwerRZ766XP+6byjDzTjwFfyfSeWDNROoA7Z6tc+6NWGOK3Cc4wqMbk1YjS0Qr6ukQCQNqvnETPQWqCVb8DwK1jNirwahjDP79e1Mt6Obfz96lNRn+qsEUp0cOkfRoy0d7Fwpj/yJbyjX9vfLRlwWULZdDnAOQV8lQIDAHQISAHeQeIMAAQLnEIgR/nvP+cjy6Fd/3cl1qjniv4lAqwUy8MvTtKMpg7x6XIE40XvyWV5CEI8cV6AaW2AsMZDJgvzsdMDBnE/Mo+osUP1vNGNPzRIYC/jzbH6e5c9bmFZBfwT8OeBkdWeTqMM6cTS+nVy0MHEnlRwD4NGv/j/KQ7/+q2X41l+PZTl8vSin3xEgQEALahsgQIDAPQj0YmC/3S/9g2Xw5KeWErexMhHopsBtSYGM5quzwhEYlryEIKb6LgTDSABUPQUiKXA68GCOLZCXEWTiIHoM1JMeA7XECp7H6jR7fuQlITlqf3bpz8A/7y6R72Uy4PQSkUwM5WPOUyRWs43Ntnbnm79xEUuY8wqbHQECBJorIAHQ3LqxZgQINF0gbvU3fP4Lyt5vf+XjA/01fZ2tH4FlCtRngutlZkDfi24Cl/KRZ/tHQWZ+r7qMIJMC2VtgLDlwPEoMVJcT1MFlzud0pvULzxcWyHrIH8f/qjrKgD+v4x8F+hnsb44H/PnV/EH+LpI2y5hiMNW9l7+yXH7eR5fyi2+JBESsn4kAAQIEzi0gAXBuMj8gQIDAiUAvDoAPP+XlZXB/jGy95+y/7YLAbAIZNOY3q/+d/OT0MoK8hmAU2Z/2GMiBBzMhEIMPVgMQ1smBeK4HHrwlOZCzqLMD9fPJYvz/Nvs8e1+d3Y+Afyu68G9mwB/X8md3/ryso/o8z/DHtOyA/2Spj/8/lj+4dq0cRZu79ZZfGN96Hv+OVwQIECAwVUACYCqRLxAgQOAuAnEwOozBqPY//hMjKBnrsnyXr3qLAIFZBG4LTvMn1dnoONObdyM4TQxk4iC/m48Yc6NODGRPgfFEQb5fJRHiDHWdTKjmefq/fDGa2pIoSJt6Sp94nUWrA/183ozAPgP8zQj067Eb8haQ48F+7ZuzWtYZ/lzWtCna2mxzN3MgwKz/00TPtB/6nAABAgRqAQmAWsIzAQIEzinQu3S5HD79GScDmp3zt+34+ljQVL0c+/u0gPleHZSMApLqs/q90y/e9mI0r1vmOz6v8a+P5nXLLG/5Y/zLXq+dQNRlVZ231WmVHIhAMIPXOjlQB64ZHJYI/I8jQVANOhjJgXyOe82fXGow9pzfq5IJo99Uv70daXx7HP9s9P74W3N9PVbm05enL06WVAXBsR51AF/dqWHkkjYZ5FfP+ToSKfm9kmf+R+telXc0zyYF+3dzjMEjs83Ntne4F3edMBEgQIDAuQUkAM5N5gcECBAIgTho7l25UnrVmai2iYwFNXWQUAVYESScnkkdBU0ZcOWgbVWQlc/xuKVb9vjZ1/z96HGaFEi7eO+WKZefAc1oPaqAJf8eBS3Vc3RZzuccaK7qwpyvY5eWr+vvnc6jDnZyfvWycj3GF3rLH+MfeN1ogboeb6u/atuJbSFHi+/Fme7TBEG8rAPe+nmQSYJ85LY79vqW93Lbrr8T23S18eSy6+Xevh6j9+uPzzKsNvHRdl59J7fzfJHP+aL6I55G23du49UjypbX6J/+Xb8/eq/+bf1vKGdZlzdf5/qfrnv1xnr8L1Y729xse4e7N0dG67Hq1pIAAQJNEYg9hokAAQIELiIwrAKG+OXoGH22eZzry7PN8sLfinWpVmdsnargPQOhCHKqM6aj666zO3UV5NcBUh0MxXerYCJXIqOdUcSz8ODi9nUf+/uWxEAGRpkUGAVIG/k8OhNaB1BVkJRJgjpRkGXJKYOk0XP1t/+tpcBd6zC3l9F2n9tE/Hcyjd6r/rit/k8D6Hy/TmzVz/ne6P3630H9b+D0dznT0fxPFxMvToP1evuL9+LuIlUyK8/U5+vqd/V3R/Op1z//rKbb1jffq9fh5Avx/9MFn76zVi9y9aNMQ5ddrVW1WVkCBJolcLrLa9ZqWRsCBAg0XCAOvoc3bsTj0VI+5EMavrK5euPBQwQK1X3YI4ivBlWLAQyP8hGDqg0i0D8aBfunZ/tHwc1oNrcGEbcHFPXf9fMCaWK1Hp/Gg59ISuT14NVUvz/68zTYGq1flSzIs6bxyO7RdYJgc6zr9GmvgjpAy3mNz/eWFRktyNP6CMxYl/W2kwXLhFL1fPL0+P/vdbsf25ZOX56+eHwx1fZ3t/fHvtLGl9nuPvZYGd68EXVwr9ZtBFImAgQITBeQAJhu5BsECBC4UyAOPnsHB2Xnf/xKufGcj4qgOYLpxkxxYFwfHFdBfAbEsX6H0WU2H/Vt1jLgzy7PeZYwv1dP1W/HD67H5ld/p9HPt6/7XVa2PjOaPR6ya/cwryceC6gyMVAnTU6TA5kUiEedHMhB1KrLDjIxkL0M6uWmZy5zbH75p6lFAqO6vaOK73ijRWVuQFGiN8/Or/1q1fYOq54RDVgnq0CAAIE1E5AAWLMKs7oECDRI4PCw9H/2p0v5rP/lJPirg8qzVnFhscFYgF5dp5zBfpwhO4hg/ygC2/rsft1tuVq//E2+GAWtVcB71oq3/f3bLE6LGxWWdXo86iFxGtDn90ePTADUA61ViYG8hVo+YuC1enyCU9ucX868+t/pUrwg0HmBWf5JVAm2YbS5PxXtW/TwuRT/xkwECBAgcG4BCYBzk/kBAQIETgSGW1tl+6f+U9l81zvK0VOeFoFiXg+/jGkUfOaiMuDPM/r7j0XAH0H/UZ7lj4C1HoivWp2x758Go8tYz7YsI/2yLNX/Hi9UlRwYXTJR4lKQahpZp3PVWyBHYI/H+K3XqoHbRr0Gqt9IDIzwPBE4WyDO+Gdbm21utr0mAgQIELiYgATAxdz8igABAieDc/3Pd5ed//f7yqNf9ccXmAAYC0Bz4ME8I10F/BF0VkH/XumdXq8/CkCr+slu7KNpljNs9Xc9n0OgTgrUz/HTtM76GETvi+yFUU2jeonEwDDHGsiEwEb0FNjKx+ie7KeXE9T1JjEwwvNEIP7NbJad7/9npUSbW/LuKyYCBAgQuJCABMCF2PyIAAECJwLDOCjd/oF/XnZe8tKy+8mfGoF5nI2fyzQKGPMsc46+n4H+/vV4RNB/uBsBfyQCqksORt/Ls9On16DPZQXM5J4F7lInkRjo5SUZUYcn0+g7mRiokgKRGDhNCmRiIP6ubnMYYwxUk6TACMJTlwSiu/9OnPnf/sHvj38nDl27VPXKSoDA/AW0ovM3NUcCBLokEN1Sc0Tqne/4lnL8bX+5HDzvYyJIjwDvIlMVwEdAmGeP8yz/XgT8e4+cBP85Wn8Gj6eB/l2Cy4ss029WIHCXusu6rXoLxJ0lMjdQbQvREyB7BWQSIJMCm5EQ2Lpy8rrqLWDgwRVUnkUuWyCC/+1f/u9l5y9+y8no/xIAy64ByyNAoGUCEgAtq1DFIUBgBQJ5QPqOt5erX//Hy+6f+say++KXxrX4cdZ+pjEBRsFgBv0ZAGbAXwf91ej0cca3TgzEPcHjr0gErKCMFrkEgdgW6nEG6oqubtMYyZ9MBtXJnxxcMMcV2IpHlRQYJQby0oJq4EGXECyhsixi0QIbsZ3Htf47P/3GSLB+c9XG5t8mAgQIELg3AQmAe/PzawIECJwI5IHpO3+zXPlTryubX/jasvsFry1HT42BAauB4kbd9etAPuO8DOYy6M/u4LsfjAAvHnldf17jnxF+NVjfKDlwsgT/76RAbgNZ8Op/JwLVOBB5l4fYXnLKbSW3rWrQwdGYAjmuQPYWyDsT1HcjqL4c21adXKj+9j8CDRLIbXkzAv8c8O/dv1WNr7Id1/0Pb8SlT4L/BlWUVSFAYJ0FJADWufasOwECzRLY3Iru27tl++9/V9n+0R8qBy97RTl+8aeUved8VOlduVIGlzbLME/OHsUZ3byWvzrTH0HccYzkXwf9dZKgWSWzNk0TuH07yURTPbbA7sMnCYEMpqpLCDIZkD0G8vKBfMTrXuz+MzFQTZICTavezq1PbovR1b9//ZFy6Zd+sWz+xI+X7Tf8h1Le9c6Ta/6jbTURIECAwHwEJADm42guBAgQOBHIMQFyhOoYqXr7+76nlB/85+Xyzk7ZuP9a2f2Tf6w89tueF8F/DBSYZ/8F/baauQpkb4GxngJV75NINh3F9lYNS5GfZ1Iggq3N7ClQ9xYYG1egSgqM5lENMll1F5jrWpoZgUrgNIk1KBvveWe58vf/ftn+mTeW8htvje117yTwN9q/jYUAAQJzF5AAmDupGRIgQCAE4vrVYV7DmkF+9AoY3LhR+tmNNc/2V4FVBlnxEF/ZXBYqMNrO6mVUSYEYnyLHqLh9XIEcbDDHFNgeSwxkD4JMCmTioJpig622WRtuTep5VoHYFusE1XFsf4cx5kle/nR0s9z3s28s2//475ZBbmvZbkZvABMBAgQILEZAAmAxruZKgACBkUAe9MbLPKgdHfzmnyYCqxMYbZO3jyuwn7eajEtS4ikD/mEG/TmGwHhvge3oLZBjDVRJgdimq0lSYATh6XaB+ix/Jp7ydqa5fe3GQKdxS9PeYXRLiZ5Qw9G1/cNtQf/tfP4mQIDAIgQkABahap4ECBCYIODc6QQcH61OoA7W6jXIy1QO456E1e0J4838vLqEIK7Hru5AMNZTIC8nyKRAPk4TCxIDNWV3nnMbGaU4c7DK3H6yp0mOeZIJptHtTPM7w9xOcnuqv98dJCUlQIDASgUkAFbKb+EECHRKICP/+tGpgivs+gpkMDcK6KptN/43iDEFclyBYZzJrZICGchF4F9dQpBJgVFiIC8lyN4C+VmVGKgVYh45r5P/1W96XkuBrPvR9lHdnSLGnDjIniQ5yGmc7c8EwPC2u6DE7Uxvqfpqu1rLwltpAgQIrKWABMBaVpuVJkBgnQVGh8vrXATr3mmB0RZcB35VABdB3ugSgiq2r8/s9sd6C2SCYDvGGMhLCjbi8OOWywgSNH5Z/bj6X6eFG1v4qs7HAv5BBvxxLf9eBPwZ+OfrTARE75FedYY/vxuPelu5S8HU9l1QvEWAAIEFCkgALBDXrAkQIHA3AQe8d1Px3toLjAeHWZhqwMFRb4ESvQXqQDCTA5kAqHoM5MCDda+BTAxEwqBKHkSvgdOgMf7FnP6jOX2x9lyNL8B4feblIIN4ZBf+vI4/H3l2Px+jgP+0frNgUYdqqvE1bAUJEOiogARARytesQkQWIXAydmw6szYKhZvmQSWLpBnf29baCYGjiKQPIzkQD2NegwM864DOfDgRiYG4vl0rIG8lCA+y+/FrTYfn+kozKyehJw15/me6zoaVVQV7MdZ/Gqk/gjw88x+DtgXj17WW92lv07oVM859sPFpmosgDs2kovNy68IECBAYLqABMB0I98gQIDA/AQiRsn4x0Sg2wIZbI5lBvLfRDVSfASYVZAZXcpzyrPQ1SN7DUTvgBxTYLN+jiRBJgjyvexRUCUR4nv5fDqN/rGd/ps7fXH6jW68SMcs6bh5nNGvg/1MxuRt+apAP3ttRMCft4rMz/NR/XQ0cF81j9F85sE5j3mcrKH/EyBAgMAMAhIAMyD5CgECBAgQILAMgVFgedr9P5aZAWIGoccRlJZ81BFjfLdOEGTPgSpBkMmBeFS9COrn2xME+bvxJEHM8nSe4y/r5eTnTZ1qr3r9xv6uEiqjAL7yO4qgfhTcZ8Cf3fkz2ZKP7N5fBfp1mUe2Ods7rOpleSZAgACBdRSQAFjHWrPOBAisp0B9bL2ea2+tCaxW4DQpMApy67XJQLcOZscD+TxTXScIMoitBh7MREE8cnDCfM5kQZU8yPdGn+VdC+rfjc+jfn1mF555/QO/rXxZznyrmn38L5dfrUP9OpMjEdwP4ox9dtvP11VQH6/zLH71XjxngD/+28pvZFQtIxdyl2VX31vw/6qyLXgZZk+AAAEClUDs7UwECBAgQIAAgXUWyEA21/8uAWwV9OY17REYV9N4tDn+u9Hr+raFOdZAJgUyeVDdsSCf4zH+eX52yyPnketw+/No0ePLr1ajDuLzeTxAj/XNs/LVmfnR67z2PgfcqwbdG3t9HH80GCgAAEAASURBVK/L6LeZJajnWy0r1yWm0+RJ/Xr0fvWh/xEgQIBAlwQkALpU28pKgMDqBfLgvDpAX/2qWAMC3RKog976eVT603+P8aJ6HYmCPGs+/v4dUHVgnR/cNr/679vfvmMeozeq5Zwu7PE3T986fTE2h7OWXy+0fn58dmM/btbLuxWvWWtobQgQINAqAQmAVlWnwhAgQIAAAQL3LhAB9GkMffpixtmOItp7CmzvZfkzrqavESBAgEAnBaLvmokAAQIECBAgQIAAAQIECBBou4AEQNtrWPkIEGiOwD2dEWxOMawJAQIE5iqgbZwrp5kRIEBgkoBLACbp+IwAAQLzFoixuh6/tnjeMzc/AgQIrJlAtokmAgQIEFiagB4AS6O2IAIECBAgQIAAAQIECBAgsDoBCYDV2VsyAQIECBAgQIAAAQIECBBYmoBLAJZGbUEECBAIgbzW1fWuNgUCBAicCGgPbQkECBBYqoAeAEvltjACBAgQIECAAAECBAgQILAaAQmA1bhbKgECXRRwpquLta7MBAhME9A2ThPyOQECBOYmIAEwN0ozIkCAAAECBAgQIECAAAECzRUwBkBz68aaESDQRoE80+VsVxtrVpkIELiIgPbwImp+Q4AAgQsL6AFwYTo/JECAAAECBAgQIECAAAEC6yMgAbA+dWVNCRAgQIAAAQIECBAgQIDAhQUkAC5M54cECBA4p4CurucE83UCBDohoG3sRDUrJAECzRAwBkAz6sFaECDQFYE80HWw25XaVk4CBKYJaA+nCfmcAAECcxWQAJgrp5kRIEBgukBv+ld8gwABAp0QEP93opoVkgCBBgm4BKBBlWFVCBAgQIAAAQIECBAgQIDAogT0AFiUrPkSIEDgdoG6+79TXrfL+JsAga4K1O1iV8uv3AQIEFiygATAksEtjgABAuJ/2wABAgQIECBAgMAqBFwCsAp1yyRAgAABAgQIECBAgAABAksWkABYMrjFESBAgAABAgQIECBAgACBVQi4BGAV6pZJgEB3BVzv2t26V3ICBO4UcE3UnSbeIUCAwAIFJAAWiGvWBAgQuFMgbwLoRoB3uniHAIFuCmgPu1nvSk2AwKoEXAKwKnnLJUCAAAECBAgQIECAAAECSxSQAFgitkURINBxAV1dO74BKD4BAncV0DbelcWbBAgQWISASwAWoWqeBAgQOEvAGABnyXifAIEuCgj+u1jrykyAwAoFJABWiG/RBAh0U8AVr92sd6UmQOBOAfH/nSbeIUCAwCIFXAKwSF3zJkCAAAECBAgQIECAAAECDRHQA6AhFWE1CBDojoAzXt2payUlQIAAAQIECDRJQAKgSbVhXQgQaLXAsL7+Xwag1fWscAQInEMg2sOqbTzHT3yVAAECBC4u4BKAi9v5JQECBM4l4Nr/c3H5MgECHRHQNnakohWTAIFGCEgANKIarAQBAl0QcOK/C7WsjAQInFdA23heMd8nQIDAxQVcAnBxO78kQIDA+QTyKLd+nO+Xvk2AAIF2CmgT21mvSkWAQGMF9ABobNVYMQIE2iagm2vbalR5CBCYh4C2cR6K5kGAAIHZBCQAZnPyLQIECBAgQIAAAQIECBAgsNYCLgFY6+qz8gQIrJ1AdHftZZdXEwECBAi4A4BtgAABAksWkABYMrjFESDQXYE67q+fuyuh5AQIEHhcQJv4uIVXBAgQWLSASwAWLWz+BAgQGAm4ztWmQIAAgTsFtI13mniHAAECixKQAFiUrPkSIEDgNgFnuW4D8ScBAgRCQNtoMyBAgMDyBFwCsDxrSyJAoOsCeZRbP7puofwECBBIAW2i7YAAAQJLFdADYKncFkaAAAECBAgQIECAAAECBFYjIAGwGndLJUCAAAECBAgQIECAAAECSxWQAFgqt4URIECAAAECBAgQIECAAIHVCBgDYDXulkqAQBcF6mtd89lEgAABAsYAsA0QIEBgyQJ6ACwZ3OIIECBAgAABAgQIECBAgMAqBCQAVqFumQQIECBAgAABAgQIECBAYMkCEgBLBrc4AgQIECBAgAABAgQIECCwCgFjAKxC3TIJEOimwLAX17uOHt0UUGoCBAjcKqBNvNXDXwQIEFiwgB4ACwY2ewIECBAgQIAAAQIECBAg0AQBPQCaUAvWgQCBTglEHwATAQIECISAm6LYDAgQILBcAQmA5XpbGgECXRZwG8Au176yEyBwN4G6XbzbZ94jQIAAgbkLSADMndQMCRAgMFnAGa/JPj4lQIAAAQIECBBYjIAxABbjaq4ECBAgQIAAAQIECBAgQKBRAhIAjaoOK0OAAAECBAgQIECAAAECBBYj4BKAxbiaKwECBO4u4HrXu7t4lwCBbgq4Jqqb9a7UBAisTEAPgJXRWzABAgQIECBAgAABAgQIEFiegATA8qwtiQABAgQIECBAgAABAgQIrEzAJQAro7dgAgQ6J1B3/9fltXNVr8AECJwhULeLZ3zsbQIECBCYr4AeAPP1NDcCBAgQIECAAAECBAgQINBIAQmARlaLlSJAgAABAgQIECBAgAABAvMVkACYr6e5ESBAgAABAgQIECBAgACBRgoYA6CR1WKlCBBopUB9rasxAFpZvQpFgMAFBOp28QI/9RMCBAgQOL+AHgDnN/MLAgQIECBAgAABAgQIECCwdgISAGtXZVaYAAECBAgQIECAAAECBAicX0AC4PxmfkGAAAECBAgQIECAAAECBNZOwBgAa1dlVpgAgbUWcL3rWleflSdAYM4CxkSZM6jZESBAYLKABMBkH58SIEBgfgKjA93e/OZoTgQIEFhrgapZlARY6zq08gQIrJeABMB61Ze1JUCgBQKOdVtQiYpAgAABAgQIEFhDAQmANaw0q0yAwBoLZPQvA7DGFWjVCRCYq4D2cK6cZkaAAIFpAgYBnCbkcwIECBAgQIAAAQIECBAg0AIBCYAWVKIiECBAgAABAgQIECBAgACBaQISANOEfE6AAAECBAgQIECAAAECBFogYAyAFlSiIhAgsCYC9fX/rnldkwqzmgQILFygbhcXviALIECAAIEU0APAdkCAAAECBAgQIECAAAECBDogoAdABypZEQkQaIpAL1akfjRlnawHAQIEVimgTVylvmUTINA9AT0AulfnSkyAAAECBAgQIECAAAECHRTQA6CDla7IBAisUMD1rivEt2gCBBonYEyUxlWJFSJAoN0CegC0u36VjgCBJgk40G1SbVgXAgSaIqBtbEpNWA8CBDogIAHQgUpWRAIECBAgQIAAAQIECBAgIAFgGyBAgAABAgQIECBAgAABAh0QMAZABypZEQkQaJCAMQAaVBlWhQCBlQvo/r/yKrACBAh0S0ACoFv1rbQECDRAIG96ZSJAgACBUsT/tgICBAgsV8AlAMv1tjQCBLos4Ei3y7Wv7AQInCWg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k7P/1EjUSiqTQkAGgEnBPHiQtlmvDoQC+NGuMIV8Kr967cm+VWu/h29jij9GYT6ARcvMXYW1OeUFEAOYNhEBERABERABERABERABEbiBALREoCmgLeLG/WMfPrULNYxBy9ywz+Fv+NBEDJOmRlKZNAIyAEwaahyIbi0Fe5ZhMXgVbRHD0oDdOx/cXZg9b3esUACeC611t22w1IJF5Tys/KaKCIiACIiACIiACIiACIhArRNg0j9oCWqKuF7F1CrULNQusZb8oxaiJqI2kuv/pN5xMgBMKm4cbOes05ZKvRYrFGCwbl33PfpEsb4h3tKAdP1Pw5i2abu509rgCQCvABUREAEREAEREAEREAEREAERiCIA7UANQS1BTRHHAMBZTWoVapao3X/8OV3/qYmojVQmlYAMAJOKe/BgnTP2muMdgxEgOhQASwMWsXxG99a7vumn0r2xqguXHb+p2dw7dpiTrceDG71WZ6z9aiMREAEREAEREAEREAEREIHqJADNQO1ADUEtETekmBqFWoWaJeaSf+lAC1ETqUw6ARkAJh05DviAU7R0w3OIeemGOI++Blg+I7dh89HelWvKyweAJTtSG7eY4+AQ9AxQEQEREAEREAEREAEREAEREIHhBBhGDM1A7WDlLS3uU6NQq8Rb8g/ahxqIWoiaSGXSCUSLz0mvUo0ccHPLBXOKLxoz9scpzAdwzydeyc1d8GrsfAAlPFNLl1tq9XoZAOIw1jYiIAIiIAIiIAIiIAIiUIsEYAAINAO0A2bxYxGgJqE2oUaJGfdvgfahBqIWUpkSAjHV55TUrfoPesect63gHzA3RijAII2u+z/1RLGp+cPoDIKDX+DM/23rLRU8zMoHUP03lc5QBERABERABERABERABMogwKR/1ArQDHG9hoO4f2gSapPYR6LmofahBlKZMgIyAEwZehzYcXy7BAuY552zUoylAZEPwJvW1tu14/6/9zLZjlhVpwHAgX1u41ZLzZmnlQFiQdNGIiACIiACIiACIiACIlADBCj+oRGoFagZ4hoAqEUCTQJtEivun1qHmofahxpIZcoIyAAwZegHD/zZ+b3m5Z+xVMylAbGmZv7WNad612/+R7jQxPPPoREgm0VCj53I6jldRoCpvuY6vgiIgAiIgAiIgAiIgAhMNQGIf2oDagRqhbjinxqEWoSaxKBNYpyGE2gd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gAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggggAACCCCAAAIIIIAAAggg8JTA/wNBn+LcyQj6ZwAAAABJRU5ErkJggmljMTEAAAVDiVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAIKADAAQAAAABAAAA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
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
<key>CFBundleVersion</key><string>0.2.3</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
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
