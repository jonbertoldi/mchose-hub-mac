import Foundation
DSP.hrirPath = ProcessInfo.processInfo.environment["MCHOSE_HRIR"]
let fs = 48000.0
guard DSP(fs: fs).debugTaps > 1 else { print("FAIL HRIR file not loaded (set MCHOSE_HRIR)"); exit(1) }
var seed: UInt64 = 777
func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: seed >> 11) % 2000000) / 1000000 - 1 }
func lp(_ x: [Float], _ fc: Double) -> [Float] { var s = 0.0; let a = Design.onePole(fs: fs, fc: fc); return x.map { s += a * (Double($0) - s); return Float(s) } }
func bandN(_ n: Int) -> [Float] { // 200-4k noise
    var h = Biquad(); h.c = Design.highpass(fs: fs, f0: 200)
    return lp(lp((0..<n).map { _ in Float(h.run(Double(rnd() * 0.3))) }, 4000), 4000)
}
func run(_ setup: (inout DSP.Params)->Void, _ l0: [Float], _ r0: [Float], chunk: Int = 512) -> ([Float],[Float]) {
    let d = DSP(fs: fs); d.update(setup)
    var l = l0, r = r0; let n = l.count
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        var o = 0; while o < n { let c = min(chunk, n - o); d.process(l: lp.baseAddress! + o, r: rp.baseAddress! + o, frames: c); o += c } } }
    return (l, r)
}
func rms(_ a: [Float], from: Int = 30000) -> Double { sqrt(a[from...].map { Double($0*$0) }.reduce(0,+) / Double(a.count - from)) }
func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
var fails = 0
func check(_ n: String, _ ok: Bool, _ d: String) { print(ok ? "PASS" : "FAIL", n, d); if !ok { fails += 1 } }
let n = 200000
let sig = (0..<n).map { Float(0.3 * sin(2 * .pi * 1000 * Double($0) / fs)) }
check("bypass exact", run({ _ in }, sig, sig).0 == sig, "")
let look = Int(0.0015 * fs)
var o = run({ $0.eqOn = true }, sig, sig); var me: Float = 0; for i in 2000..<190000 { me = max(me, abs(o.0[i] - sig[i - look])) }
check("EQ zero-gain null", me < 1e-6, "\(me)")
// EQ centre accuracy (Treble preset): response at each band centre equals its slider (relative to the preamp)
let treble = [-10.0, -11, -12, -6, 2, 8, 13, 13, 11, 14]
let probe = DSP(fs: fs); probe.update { $0.eqOn = true; $0.gains = treble }
var worst = 0.0
for (i, f) in DSP.bandFreqs.enumerated() {
    let x = (0..<96000).map { Float(0.02 * sin(2 * .pi * f * Double($0) / fs)) }
    let y = run({ $0.eqOn = true; $0.gains = treble }, x, x)
    worst = max(worst, abs(db(rms(y.0, from: 48000) / rms(x, from: 48000)) - probe.preampDB - treble[i]))
}
check("EQ centre accuracy (Treble)", worst < 0.7, String(format: "worst %.2f dB", worst))
let hot = (0..<n).map { Float(1.8 * sin(2 * .pi * 100 * Double($0) / fs)) }
o = run({ $0.eqOn = true }, hot, hot); let pk = o.0[4000...].map { abs($0) }.max()!
check("limiter ceiling", pk <= 0.8915, "\(pk)")
let L = bandN(n), R = bandN(n)
// block-size independence: 64 vs 4096
let a = run({ $0.surroundOn = true }, L, R, chunk: 64), b = run({ $0.surroundOn = true }, L, R, chunk: 4096)
var md: Float = 0; for i in 0..<n { md = max(md, abs(a.0[i] - b.0[i])) }
check("surround block-size independent", md < 1e-4, "max diff \(md)")
// loudness
let mono = run({ $0.surroundOn = true }, L, L)
let dry = rms(L)
print(String(format: "mono: L %.2f dB R %.2f dB vs dry", db(rms(mono.0)/dry), db(rms(mono.1)/dry)))
let side = run({ $0.surroundOn = true }, L, L.map { -$0 })
print(String(format: "side: L %.2f dB R %.2f dB vs dry", db(rms(side.0)/dry), db(rms(side.1)/dry)))
let unc = run({ $0.surroundOn = true }, L, R)
let dryU = sqrt((rms(L)*rms(L) + rms(R)*rms(R))/2)
print(String(format: "uncorrelated: L %.2f dB R %.2f dB vs dry", db(rms(unc.0)/dryU), db(rms(unc.1)/dryU)))
check("mono within 1.5 dB", abs(db(rms(mono.0)/dry)) < 1.5, "")
check("mono L/R balance", abs(db(rms(mono.0)/rms(mono.1))) < 1.0, "")
// hard-left cue
let z = [Float](repeating: 0, count: n)
let h = run({ $0.surroundOn = true }, L, z)
var sl = 0.0, sr = 0.0, sx = 0.0
for i in 30000..<n { sl += Double(h.0[i]*h.0[i]); sr += Double(h.1[i]*h.1[i]); sx += Double(h.0[i]*h.1[i]) }
print(String(format: "hard-left: R/L %.1f dB, interaural corr %.2f", 10*log10(sr/sl), sx/sqrt(sl*sr)))
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
if fails > 0 { exit(1) }
