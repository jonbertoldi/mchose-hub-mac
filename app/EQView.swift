import SwiftUI

struct Preset: Decodable, Identifiable { let name: String; let data: [Double]; var id: String { name } }
struct Presets: Decodable {
    let game: [Preset]; let music: [Preset]
    static let shared: Presets = {
        guard let u = Bundle.main.url(forResource: "Presets", withExtension: "json"),
              let d = try? Data(contentsOf: u), let p = try? JSONDecoder().decode(Presets.self, from: d)
        else { return Presets(game: [], music: []) }
        return p
    }()
}

struct EQView: View {
    @ObservedObject var p: Processor
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Enable audio processing", isOn: Binding(get: { p.running }, set: { $0 ? p.start() : p.stop() }))
                    .toggleStyle(.switch)
                Spacer()
                Text(p.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("Captures system audio and plays it to the headset. Turn headset volume down before first use.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Toggle("10-band EQ", isOn: $p.eqOn)
                Text(String(format: "preamp %.1f dB", p.eqOn ? p.dsp.preampDB : 0)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Menu(p.presetName) {
                    Section("Game") { ForEach(Presets.shared.game) { pr in Button(pr.name) { apply(pr) } } }
                    Section("Music") { ForEach(Presets.shared.music) { pr in Button(pr.name) { apply(pr) } } }
                }.fixedSize()
                Button("Reset") { p.presetName = "Custom"; p.gains = [Double](repeating: 0, count: 10) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<10, id: \.self) { b in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", p.gains[b])).font(.caption2).monospacedDigit()
                        Slider(value: Binding(get: { p.gains[b] }, set: { p.gains[b] = $0; p.presetName = "Custom" }), in: -12...12, step: 1)
                            .frame(width: 130).rotationEffect(.degrees(-90)).frame(width: 24, height: 130)
                        Text(Self.labels[b]).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.opacity(p.eqOn ? 1 : 0.4)
            Divider()
            Toggle("Virtual 7.1 surround (binaural)", isOn: $p.surroundOn)
            HStack {
                Text("Amount").font(.caption)
                Slider(value: $p.surroundMix, in: 0...1)
            }.opacity(p.surroundOn ? 1 : 0.4)
        }
        .padding(18).frame(width: 520)
    }

    private func apply(_ pr: Preset) {
        p.presetName = pr.name
        p.gains = Array((pr.data + [Double](repeating: 0, count: 10)).prefix(10))
        p.eqOn = true
    }
}
