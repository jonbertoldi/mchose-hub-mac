import SwiftUI
import IOKit.hid

// Protocol: see ../FINDINGS.md. HID report 0x55, 63-byte payload.
final class Headset: ObservableObject {
    @Published var connected = false
    @Published var battery: Int?
    @Published var charging: String = ""
    @Published var mode: Int?
    @Published var shutdownMinutes: Int?
    @Published var promptVolume: Int?

    static let shutdownValue: [Int: UInt8] = [15: 1, 30: 4, 45: 0]
    static let modeNames = ["Game 1", "Game 2", "Music"]

    private let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var dev: IOHIDDevice?
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var timer: Timer?

    init() {
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x3837, kIOHIDProductIDKey: 0x600A] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, d in
            Unmanaged<Headset>.fromOpaque(ctx!).takeUnretainedValue().attach(d)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, d in
            Unmanaged<Headset>.fromOpaque(ctx!).takeUnretainedValue().detach(d)
        }, me)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.send([0x65, 0x01]) }
    }

    private func attach(_ d: IOHIDDevice) {
        dev = d
        connected = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, inBuf, 64, { ctx, _, _, _, id, rep, len in
            let b = Array(UnsafeBufferPointer(start: rep, count: len))
            DispatchQueue.main.async { Unmanaged<Headset>.fromOpaque(ctx!).takeUnretainedValue().parse(id, b) }
        }, me)
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        refresh()
    }

    private func detach(_ d: IOHIDDevice) {
        guard d == dev else { return }
        dev = nil; connected = false
        battery = nil; mode = nil; shutdownMinutes = nil; promptVolume = nil
    }

    // Replies are separate input reports, so space queries out a little.
    func refresh() {
        let qs: [[UInt8]] = [[0x65, 0x01], [0x11], [0x22, 0x02], [0x22, 0x04]]
        for (i, q) in qs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(i)) { self.send(q) }
        }
    }

    func send(_ payload: [UInt8]) {
        guard let d = dev else { return }
        var out = [UInt8](repeating: 0, count: 64)
        out[0] = 0x55
        for (i, v) in payload.prefix(63).enumerated() { out[1 + i] = v }
        IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x55, out, out.count)
    }

    private func parse(_ id: UInt32, _ b: [UInt8]) {
        guard id == 0x55, b.count >= 4 else { return }
        switch b[1] {
        case 0x65:
            battery = Int(b[2])
            charging = [3: "Charging", 4: "Full", 2: ""][Int(b[3])] ?? (b[3] == 26 ? "Asleep" : "")
        case 0x11: mode = Int(b[2])
        case 0x22:
            if b[2] == 2 { shutdownMinutes = Self.shutdownValue.first { $0.value == b[3] }?.key }
            if b[2] == 4 { promptVolume = Int(b[3]) }
        default: break
        }
    }

    // Set commands: write, then read back to confirm.
    func setMode(_ m: Int) { send([0x21, 0x01, UInt8(m)]); mode = m }
    func setShutdown(_ min: Int) {
        guard let v = Self.shutdownValue[min] else { return }
        send([0x22, 0x00, v]); shutdownMinutes = min
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.send([0x22, 0x02]) }
    }
    func setPromptVolume(_ v: Int) {
        send([0x22, 0x03, UInt8(max(1, min(16, v)))]); promptVolume = v
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.send([0x22, 0x04]) }
    }
}

struct Seg: View {
    let labels: [String]
    let selected: Int?
    let tap: (Int) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.indices, id: \.self) { i in
                Button(labels[i]) { tap(i) }
                    .buttonStyle(.borderedProminent)
                    .tint(selected == i ? .accentColor : .gray.opacity(0.35))
            }
        }
    }
}

struct MenuView: View {
    @ObservedObject var h: Headset
    @ObservedObject var p: Processor
    @Environment(\.openWindow) private var openWindow
    @State private var draftVolume: Double = 1
    @State private var dragging = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MCHOSE V9 Turbo+").font(.headline)
            if !h.connected {
                Text("Headset not connected").foregroundStyle(.secondary)
            } else {
                HStack {
                    Image(systemName: "battery.100")
                    Text(h.battery.map { "\($0)%" } ?? "-")
                    if !h.charging.isEmpty { Text(h.charging).foregroundStyle(.secondary) }
                }
                Text("Sound mode").font(.caption).foregroundStyle(.secondary)
                Seg(labels: Headset.modeNames, selected: h.mode) { h.setMode($0) }
                Text("Auto shutdown").font(.caption).foregroundStyle(.secondary)
                Seg(labels: ["15 min", "30 min", "45 min"], selected: [15: 0, 30: 1, 45: 2][h.shutdownMinutes ?? 0] .flatMap { h.shutdownMinutes == nil ? nil : $0 }) { h.setShutdown([15, 30, 45][$0]) }
                Text("Prompt volume").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $draftVolume, in: 1...16, step: 1) { editing in
                        dragging = editing
                        if !editing { h.setPromptVolume(Int(draftVolume)) }
                    }
                    Text("\(Int(draftVolume))").monospacedDigit().frame(width: 24)
                }
                .onReceive(h.$promptVolume) { v in if let v, !dragging { draftVolume = Double(min(16, max(1, v))) } }
                Button("Refresh") { h.refresh() }
            }
            Divider()
            HStack {
                Toggle("EQ / 7.1", isOn: Binding(get: { p.running }, set: { $0 ? p.start() : p.stop() })).toggleStyle(.switch)
                Spacer()
                Button("Equalizer…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "eq") }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14).frame(width: 300)
    }
}

@main struct MchoseApp: App {
    @StateObject var h = Headset()
    @StateObject var p = Processor()
    var body: some Scene {
        MenuBarExtra {
            MenuView(h: h, p: p)
        } label: {
            Image(systemName: "headphones")
            if let b = h.battery { Text("\(b)%") }
        }.menuBarExtraStyle(.window)
        Window("Equalizer", id: "eq") { EQView(p: p) }.windowResizability(.contentSize)
    }
}
