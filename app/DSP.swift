import Foundation
import os
import Accelerate

// Stereo EQ + virtual 7.1 binaural + lookahead limiter.
// Threading: update()/configure() run on the main thread (configure only while the audio callback is stopped).
// process() runs on the audio thread and never allocates or takes a blocking lock.

struct Coef { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }

struct Biquad {
    var c = Coef()
    var z1 = 0.0, z2 = 0.0
    @inline(__always) mutating func run(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
    mutating func reset() { z1 = 0; z2 = 0 }
}

enum Design {
    static func peaking(fs: Double, f0: Double, q: Double, gainDB: Double) -> Coef {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q), c = cos(w0), a0 = 1 + alpha / A
        return Coef(b0: (1 + alpha * A) / a0, b1: -2 * c / a0, b2: (1 - alpha * A) / a0, a1: -2 * c / a0, a2: (1 - alpha / A) / a0)
    }
    /// RBJ high shelf, slope S = 1.
    static func highShelf(fs: Double, f0: Double, gainDB: Double) -> Coef {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / fs
        let c = cos(w0), alpha = sin(w0) / 2 * sqrt((A + 1 / A) * (1 / 1 - 1) + 2)
        let t = 2 * sqrt(A) * alpha
        let a0 = (A + 1) - (A - 1) * c + t
        return Coef(b0: A * ((A + 1) + (A - 1) * c + t) / a0, b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
                    b2: A * ((A + 1) + (A - 1) * c - t) / a0, a1: 2 * ((A - 1) - (A + 1) * c) / a0,
                    a2: ((A + 1) - (A - 1) * c - t) / a0)
    }
    static func highpass(fs: Double, f0: Double, q: Double = 0.7071) -> Coef {
        let w0 = 2 * Double.pi * f0 / fs, c = cos(w0), alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        return Coef(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
    static func onePole(fs: Double, fc: Double) -> Double { 1 - exp(-2 * .pi * fc / fs) }

    static func magnitudeDB(_ q: Coef, fs: Double, f: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = q.b0 + q.b1 * c1 + q.b2 * c2, ni = -(q.b1 * s1 + q.b2 * s2)
        let dr = 1 + q.a1 * c1 + q.a2 * c2, di = -(q.a1 * s1 + q.a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
}

/// Immutable parameter set built on the main thread, read by the audio thread.
final class Snapshot {
    var eqOn = false
    var eq = [Coef](repeating: Coef(), count: 10)
    var preTarget: Float = 1
    var preDB = 0.0
    var surroundOn = false
    var mixTarget: Float = 0
    var master: Float = 1
}

final class DSP {
    static let bandFreqs: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let q = 1.41
    static let shelfF0 = 11300.0     // 16 kHz band is a high shelf (avoids Nyquist cramping of a peaking band)
    static let wetNorm: Float = 0.55  // wet path loudness match to dry, calibrated offline

    struct Params {
        var eqOn = false
        var gains = [Double](repeating: 0, count: 10)
        var surroundOn = false
        var surroundMix: Float = 1
        var master: Float = 1
    }

    private(set) var fs: Double
    private var params = Params()
    private var lock = os_unfair_lock()
    private var published: Snapshot?
    private var keep: [Snapshot] = []          // keeps old snapshots alive so they are freed on the main thread
    private var cur = Snapshot()               // audio thread only

    // MARK: audio-thread state (fixed-size, allocated once)
    private let ringN = 8192
    private var eqL = [Biquad](repeating: Biquad(), count: 10)
    private var eqR = [Biquad](repeating: Biquad(), count: 10)
    private var pre: Float = 1, mix: Float = 0, mst: Float = 1
    private var smoothC: Float = 0
    private var wasWet = false

    // Virtual 7.1: 6 virtual speakers (+-30, +-90, +-135) rendered with measured KEMAR HRIRs.
    // 5 mono sources x 2 ears = 10 FIRs per sample (stereo: FL=L, FR=R, sides=+-S, backs = decorrelated delayed S).
    static let maxTaps = 512
    static let maxBlock = 4096
    private var taps = 140
    private let kern: UnsafeMutablePointer<Float>      // [5 src][2 ear][maxTaps], stored reversed for vDSP_conv
    private let hist: UnsafeMutablePointer<Float>      // [5 src][maxTaps + maxBlock]
    private let outE: UnsafeMutablePointer<Float>      // [2 ear][maxBlock]
    private let tmp: UnsafeMutablePointer<Float>
    private let dryB: UnsafeMutablePointer<Float>      // [2][maxBlock]
    private let mixB: UnsafeMutablePointer<Float>
    private let sRing: UnsafeMutablePointer<Double>
    private let mRing: UnsafeMutablePointer<Double>
    private var sW = 0
    private var hpS = Biquad(), hpM = Biquad()
    private var backLP = 0.0, backLPa = 0.0
    private var apX1 = [0.0, 0.0], apY1 = [0.0, 0.0]
    private var backDelay = 720
    private var refL = [Int](repeating: 0, count: 5), refR = [Int](repeating: 0, count: 5)
    private var refLP = [0.0, 0.0], refLPa = 0.0
    private let refGL: [Double] = [0.20, -0.16, 0.125, -0.10, 0.08]
    private let refGR: [Double] = [-0.20, 0.16, -0.125, 0.10, -0.08]
    static var hrirPath: String? = Bundle.main.path(forResource: "hrir48", ofType: "bin")
    static let spkGain: [Double] = [1.0, 1.0, 0.3, 0.3, 0.25, 0.25]   // FL FR SL SR BL BR

    // limiter
    private let limN = 512
    private var look = 72
    private let dly: UnsafeMutablePointer<Float>      // interleaved delay line (L,R)
    private let rq: UnsafeMutablePointer<Float>
    private let mnRing: UnsafeMutablePointer<Float>
    private var limW = 0, mnSum: Float = 0
    private var env: Float = 1, relC: Float = 0
    static let ceiling: Float = 0.891    // -1 dBFS

    init(fs: Double = 48000) {
        self.fs = fs
        kern = .allocate(capacity: 10 * DSP.maxTaps); kern.initialize(repeating: 0, count: 10 * DSP.maxTaps)
        hist = .allocate(capacity: 5 * (DSP.maxTaps + DSP.maxBlock)); hist.initialize(repeating: 0, count: 5 * (DSP.maxTaps + DSP.maxBlock))
        outE = .allocate(capacity: 2 * DSP.maxBlock); outE.initialize(repeating: 0, count: 2 * DSP.maxBlock)
        tmp = .allocate(capacity: DSP.maxBlock); tmp.initialize(repeating: 0, count: DSP.maxBlock)
        dryB = .allocate(capacity: 2 * DSP.maxBlock); dryB.initialize(repeating: 0, count: 2 * DSP.maxBlock)
        mixB = .allocate(capacity: DSP.maxBlock); mixB.initialize(repeating: 0, count: DSP.maxBlock)
        sRing = .allocate(capacity: 8192); sRing.initialize(repeating: 0, count: 8192)
        mRing = .allocate(capacity: 8192); mRing.initialize(repeating: 0, count: 8192)
        dly = .allocate(capacity: 1024); dly.initialize(repeating: 0, count: 1024)
        rq = .allocate(capacity: 512); rq.initialize(repeating: 1, count: 512)
        mnRing = .allocate(capacity: 512); mnRing.initialize(repeating: 1, count: 512)
        configure(fs: fs)
    }

    // MARK: main thread
    func configure(fs: Double) {
        self.fs = fs
        smoothC = Float(1 - exp(-1 / (0.01 * fs)))
        look = min(200, Int(0.0015 * fs)); relC = Float(1 - exp(-1 / (0.08 * fs)))
        mnSum = Float(look + 1)
        for i in 0..<limN { rq[i] = 1; mnRing[i] = 1 }
        for i in 0..<1024 { dly[i] = 0 }
        env = 1; limW = 0
        loadHRIR(fs: fs)
        hpS.c = Design.highpass(fs: fs, f0: 150); hpM.c = Design.highpass(fs: fs, f0: 150)
        hpS.reset(); hpM.reset()
        backDelay = Int(0.015 * fs); backLPa = Design.onePole(fs: fs, fc: 7000)
        refLPa = Design.onePole(fs: fs, fc: 6000)
        let ms: ([Double], [Double]) = ([7.1, 11.3, 16.7, 23.9, 31.1], [8.3, 12.9, 18.1, 26.3, 33.7])
        refL = ms.0.map { Int($0 * 0.001 * fs) }; refR = ms.1.map { Int($0 * 0.001 * fs) }
        for i in 0..<8192 { sRing[i] = 0; mRing[i] = 0 }
        sW = 0; backLP = 0; apX1 = [0, 0]; apY1 = [0, 0]; refLP = [0, 0]
        for b in 0..<10 { eqL[b].reset(); eqR[b].reset() }
        rebuild()
    }

    /// Loads 48 kHz KEMAR HRIRs (order: -30,30,-90,90,-135,135; L ear then R ear) and resamples to `fs` if needed.
    private func loadHRIR(fs: Double) {
        guard let path = DSP.hrirPath, let d = FileManager.default.contents(atPath: path), d.count > 8 else { taps = 1; for i in 0..<(10 * DSP.maxTaps) { kern[i] = 0 }; return }
        let n0 = Int(d.withUnsafeBytes { $0.load(as: Int32.self) })
        let f: [Float] = d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self).dropFirst(1)) }
        func h(_ spk: Int, _ ear: Int) -> [Double] { (0..<n0).map { Double(f[(spk * 2 + ear) * n0 + $0]) } }
        let ratio = fs / 48000
        let n = min(DSP.maxTaps, Int((Double(n0) * ratio).rounded(.up)))
        func rs(_ x: [Double]) -> [Double] {
            if abs(ratio - 1) < 1e-9 { return x }
            return (0..<n).map { k in
                let t = Double(k) / ratio, i = Int(t), fr = t - Double(i)
                let a = i < x.count ? x[i] : 0, b = i + 1 < x.count ? x[i + 1] : 0
                return a + (b - a) * fr
            }
        }
        taps = n
        var k: [[[Double]]] = []   // k[spk][ear]
        for sp in 0..<6 { k.append([rs(h(sp, 0)), rs(h(sp, 1))]) }
        let g = DSP.spkGain
        for ear in 0..<2 {
            var src = [[Double]](repeating: [Double](repeating: 0, count: n), count: 5)
            for t in 0..<n {
                src[0][t] = k[0][ear][t] * g[0]                               // L  -> FL
                src[1][t] = k[1][ear][t] * g[1]                               // R  -> FR
                src[2][t] = k[2][ear][t] * g[2] - k[3][ear][t] * g[3]         // S  -> SL(+) SR(-)
                src[3][t] = k[4][ear][t] * g[4]                               // yL -> BL
                src[4][t] = -k[5][ear][t] * g[5]                              // yR -> -BR
            }
            for j in 0..<5 {
                let base = (j * 2 + ear) * DSP.maxTaps
                for t in 0..<DSP.maxTaps { kern[base + t] = t < n ? Float(src[j][n - 1 - t]) : 0 }   // reversed
            }
        }
        for i in 0..<(5 * (DSP.maxTaps + DSP.maxBlock)) { hist[i] = 0 }
    }

    func update(_ f: (inout Params) -> Void) { f(&params); rebuild() }

    /// Interaction-compensated band gains: after compensation the response at each band centre equals its slider.
    static func compensated(fs: Double, target: [Double]) -> [Double] {
        func coefs(_ g: [Double]) -> [Coef] {
            (0..<10).map { $0 == 9 ? Design.highShelf(fs: fs, f0: shelfF0, gainDB: g[9])
                                   : Design.peaking(fs: fs, f0: bandFreqs[$0], q: q, gainDB: g[$0]) }
        }
        if target.allSatisfy({ $0 == 0 }) { return target }
        var g = target
        for _ in 0..<30 {
            let cs = coefs(g)
            for i in 0..<10 {
                let h = cs.reduce(0.0) { $0 + Design.magnitudeDB($1, fs: fs, f: bandFreqs[i]) }
                g[i] = max(-24, min(24, g[i] + 0.7 * (target[i] - h)))
            }
        }
        return g
    }

    private func rebuild() {
        let s = Snapshot()
        s.eqOn = params.eqOn
        let g = params.eqOn ? DSP.compensated(fs: fs, target: params.gains) : [Double](repeating: 0, count: 10)
        s.eq = (0..<10).map { $0 == 9 ? Design.highShelf(fs: fs, f0: DSP.shelfF0, gainDB: g[9])
                                      : Design.peaking(fs: fs, f0: DSP.bandFreqs[$0], q: DSP.q, gainDB: g[$0]) }
        var peak = 0.0
        var f = 20.0
        while f < 20000 { peak = max(peak, s.eq.reduce(0.0) { $0 + Design.magnitudeDB($1, fs: fs, f: f) }); f *= 1.03 }
        s.preDB = max(-18, min(0, -(peak - 3)))
        if peak <= 3 { s.preDB = 0 }
        s.preTarget = Float(pow(10, s.preDB / 20))
        s.surroundOn = params.surroundOn
        s.mixTarget = params.surroundOn ? params.surroundMix : 0
        s.master = params.master
        keep.append(s); if keep.count > 32 { keep.removeFirst() }
        os_unfair_lock_lock(&lock); published = s; os_unfair_lock_unlock(&lock)
    }

    var debugMix: Float { mix }
    var debugTaps: Int { taps }
    var debugOn: Bool { cur.surroundOn }

    /// Current preamp attenuation in dB (for the UI).
    var preampDB: Double { keep.last?.preDB ?? 0 }

    // MARK: audio thread
    func process(l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) {
            if let p = published { cur = p }
            os_unfair_lock_unlock(&lock)
        }
        let s = cur
        if !s.eqOn && !s.surroundOn && s.master == 1 && mix < 1e-4 && abs(pre - 1) < 1e-4 { return }
        var off = 0
        while off < frames {
            let n = min(DSP.maxBlock, frames - off)
            block(s, l + off, r + off, n)
            off += n
        }
    }

    private func block(_ s: Snapshot, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        let eqc = s.eq
        for b in 0..<10 { eqL[b].c = eqc[b]; eqR[b].c = eqc[b] }
        let sc = smoothC
        let T = taps, H = DSP.maxTaps + DSP.maxBlock
        let wet0 = mix > 1e-4 || s.mixTarget > 1e-4
        if wet0 && !wasWet {   // restarting after idle: drop stale tails
            wasWet = true
            for k in 0..<(5 * H) { hist[k] = 0 }
            for k in 0..<8192 { sRing[k] = 0; mRing[k] = 0 }
            apX1 = [0, 0]; apY1 = [0, 0]; backLP = 0; refLP = [0, 0]; hpS.reset(); hpM.reset()
        }

        // stage 1: preamp, EQ, source generation
        let keep = T - 1
        for i in 0..<n {
            pre += (s.preTarget - pre) * sc
            mix += (s.mixTarget - mix) * sc
            mst += (s.master - mst) * sc
            var dl = Double(l[i] * pre), dr = Double(r[i] * pre)
            for b in 0..<10 { dl = eqL[b].run(dl); dr = eqR[b].run(dr) }
            dryB[i] = Float(dl); dryB[DSP.maxBlock + i] = Float(dr)
            mixB[i] = mix
            if wet0 {
                let sh = hpS.run((dl - dr) * 0.5)
                sRing[sW & 8191] = sh
                mRing[sW & 8191] = hpM.run((dl + dr) * 0.5)
                var bd = sRing[(sW - backDelay) & 8191]
                backLP += backLPa * (bd - backLP); bd = backLP
                let a0 = 0.6   // first-order allpass decorrelators, opposite sign per back speaker
                let yL = -a0 * bd + apX1[0] + a0 * apY1[0]; apX1[0] = bd; apY1[0] = yL
                let yR = a0 * bd + apX1[1] - a0 * apY1[1]; apX1[1] = bd; apY1[1] = yR
                hist[0 * H + keep + i] = Float(dl); hist[1 * H + keep + i] = Float(dr)
                hist[2 * H + keep + i] = Float(sh)
                hist[3 * H + keep + i] = Float(yL); hist[4 * H + keep + i] = Float(yR)
                sW &+= 1
            }
        }

        // stage 2: 10 FIRs (vDSP_conv), only while the virtualiser is audible
        if wet0 {
            for ear in 0..<2 {
                let o = outE + ear * DSP.maxBlock
                for j in 0..<5 {
                    let src = hist + j * H
                    let k = kern + (j * 2 + ear) * DSP.maxTaps
                    if j == 0 { vDSP_conv(src, 1, k, 1, o, 1, vDSP_Length(n), vDSP_Length(T)) }
                    else { vDSP_conv(src, 1, k, 1, tmp, 1, vDSP_Length(n), vDSP_Length(T)); vDSP_vadd(o, 1, tmp, 1, o, 1, vDSP_Length(n)) }
                }
            }
            for j in 0..<5 {   // keep history for the next block
                let src = hist + j * H
                memmove(src, src + n, keep * MemoryLayout<Float>.size)
            }
        }

        // stage 3: mix, reflections, master, limiter
        let N = look, M = N + 1
        for i in 0..<n {
            var ol = dryB[i], or = dryB[DSP.maxBlock + i]
            let m = mixB[i]
            if wet0 {
                let w = sW - n + i
                var eL = 0.0, eR = 0.0
                for t in 0..<5 {
                    eL += refGL[t] * mRing[(w - refL[t]) & 8191]
                    eR += refGR[t] * mRing[(w - refR[t]) & 8191]
                }
                refLP[0] += refLPa * (eL - refLP[0]); refLP[1] += refLPa * (eR - refLP[1])
                let wl = outE[i] + Float(refLP[0]) * 0.6, wr = outE[DSP.maxBlock + i] + Float(refLP[1]) * 0.6
                ol = ol * (1 - m) + wl * DSP.wetNorm * m
                or = or * (1 - m) + wr * DSP.wetNorm * m
            }
            ol *= mst; or *= mst

            // lookahead stereo-linked peak limiter (-1 dBFS)
            let pk = max(abs(ol), abs(or))
            let req: Float = pk > DSP.ceiling ? DSP.ceiling / pk : 1
            rq[limW & 511] = req
            var mn: Float = 1
            for k in 0...N { mn = min(mn, rq[(limW - k) & 511]) }
            mnSum += mn - mnRing[(limW - M) & 511]
            mnRing[limW & 511] = mn
            let avg = mnSum / Float(M)
            if avg < env { env = avg } else { env += (avg - env) * relC }
            dly[(limW & 511) * 2] = ol; dly[(limW & 511) * 2 + 1] = or
            let di = ((limW - N) & 511) * 2
            l[i] = dly[di] * env; r[i] = dly[di + 1] * env
            limW &+= 1
        }
        if !wet0 { wasWet = false }
    }
}
