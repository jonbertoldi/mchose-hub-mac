import Foundation
import CoreAudio
import AudioToolbox
import SwiftUI

/// Taps system audio, runs it through DSP and plays it to the MCHOSE headset.
/// The tap excludes this process (no feedback) and mutes the original path only while running.
final class Processor: ObservableObject {
    @Published var running = false
    @Published var status = "Off"
    @Published var eqOn: Bool { didSet { push(); save() } }
    @Published var surroundOn: Bool { didSet { push(); save() } }
    @Published var surroundMix: Double { didSet { push(); save() } }
    @Published var gains: [Double] { didSet { push(); save() } }
    @Published var presetName = "Custom"

    let dsp = DSP()
    var peakIn: Float = 0, peakOut: Float = 0   // diagnostics only
    var diag = CommandLine.arguments.contains("--diag")
    var diagInfo = ""
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let cap = 8192
    private let sl: UnsafeMutablePointer<Float>
    private let sr: UnsafeMutablePointer<Float>

    init() {
        let d = UserDefaults.standard
        eqOn = d.bool(forKey: "eqOn")
        surroundOn = d.bool(forKey: "surroundOn")
        surroundMix = d.object(forKey: "surroundMix") as? Double ?? 1
        gains = (d.array(forKey: "gains") as? [Double]) ?? [Double](repeating: 0, count: 10)
        sl = .allocate(capacity: cap); sr = .allocate(capacity: cap)
        push()
        if CommandLine.arguments.contains("--selftest") { selfTest() }
    }

    private func selfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            eqOn = true; gains = [3, 2, 1, 0, 0, 0, 0, 0, 0, 0]; surroundOn = true
            dsp.update { $0.master = 0.2 }
            start()
            var log = "start: \(status) running=\(running)\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
                log += "diag: \(diagInfo)\n"
                log += "debug: surroundOn=\(dsp.debugOn) mix=\(dsp.debugMix) eqPre=\(dsp.preampDB)\n"
                log += "peakIn=\(peakIn) peakOut=\(peakOut)\n"
                stop(); log += "stopped: \(status)\n"
                try? log.write(toFile: NSTemporaryDirectory() + "mchosehub-selftest.log", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    private var selfTesting = CommandLine.arguments.contains("--selftest")
    private func save() {
        if selfTesting { return }
        let d = UserDefaults.standard
        d.set(eqOn, forKey: "eqOn"); d.set(surroundOn, forKey: "surroundOn")
        d.set(surroundMix, forKey: "surroundMix"); d.set(gains, forKey: "gains")
    }

    private func push() {
        let (e, s, m, g) = (eqOn, surroundOn, Float(surroundMix), gains)
        dsp.update { $0.eqOn = e; $0.surroundOn = s; $0.surroundMix = m; $0.gains = g }
    }

    // MARK: Core Audio helpers
    private static func prop(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func findHeadsetOutput() -> (AudioObjectID, String)? {
        var a = prop(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        for id in ids {
            var n = prop(kAudioObjectPropertyName)
            var name: CFString = "" as CFString
            var s = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(id, &n, 0, nil, &s, &name)
            guard (name as String).contains("MCHOSE") else { continue }
            var o = prop(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var os: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &o, 0, nil, &os)
            guard os > 0 else { continue }
            var u = prop(kAudioDevicePropertyDeviceUID)
            var uid: CFString = "" as CFString
            var us = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(id, &u, 0, nil, &us, &uid)
            return (id, uid as String)
        }
        return nil
    }

    private func ownProcessObject(on device: AudioObjectID) -> AudioObjectID? {
        // Registering as an audio client makes our process visible to the HAL.
        var tmp: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&tmp, device, nil) { _, _, _, out, _ in
            let l = UnsafeMutableAudioBufferListPointer(out)
            for b in l { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        guard let t = tmp else { return nil }
        AudioDeviceStart(device, t)
        var a = Self.prop(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid(), obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        AudioDeviceStop(device, t)
        AudioDeviceDestroyIOProcID(device, t)
        return (err == 0 && obj != kAudioObjectUnknown) ? obj : nil
    }

    // MARK: start / stop
    func start() {
        guard !running else { return }
        guard let (dev, uid) = Self.findHeadsetOutput() else { status = "Headset audio output not found"; return }
        // Safety: never tap without excluding ourselves (would feed back).
        guard let me = ownProcessObject(on: dev) else { status = "Could not identify own audio process"; return }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        desc.name = "MchoseHub tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == 0 else { status = "Tap failed (\(err)). Allow System Audio Recording for MchoseHub in Privacy settings."; return }

        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MchoseHub",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard err == 0 else { teardown(); status = "Aggregate device failed (\(err))"; return }

        var ra = Self.prop(kAudioDevicePropertyNominalSampleRate)
        var fs: Float64 = 48000; var fsz = UInt32(8)
        AudioObjectGetPropertyData(aggID, &ra, 0, nil, &fsz, &fs)
        dsp.configure(fs: fs)
        push()

        let cap = self.cap, sl = self.sl, sr = self.sr, dsp = self.dsp
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            let inL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            let outL = UnsafeMutableAudioBufferListPointer(outData)
            if self.diag {
                for b in outL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                var s = "in:"
                for (k, b) in inL.enumerated() {
                    var pk: Float = 0
                    if let d = b.mData { let f = d.assumingMemoryBound(to: Float.self); for j in 0..<Int(b.mDataByteSize) / 4 { let v = f[j]; pk = max(pk, v.isFinite ? abs(v) : 9) } }
                    s += " [\(k) ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize) peak=\(pk)]"
                }
                s += " out:"
                for (k, b) in outL.enumerated() { s += " [\(k) ch=\(b.mNumberChannels) bytes=\(b.mDataByteSize)]" }
                self.diagInfo = s
                return
            }
            // tap = the interleaved stereo float buffer on the input side; headset mic is mono.
            guard let tb = inL.first(where: { $0.mNumberChannels == 2 }), let tin = tb.mData,
                  let ob = outL.first(where: { $0.mNumberChannels == 2 }), let oout = ob.mData else {
                for b in outL { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
                return
            }
            let frames = min(Int(tb.mDataByteSize) / 8, Int(ob.mDataByteSize) / 8)
            if frames > cap { memset(oout, 0, Int(ob.mDataByteSize)); return }
            let i = tin.assumingMemoryBound(to: Float.self), o = oout.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { sl[f] = i[2 * f]; sr[f] = i[2 * f + 1] }
            var pi: Float = 0
            for f in 0..<frames { pi = max(pi, abs(sl[f]), abs(sr[f])) }
            dsp.process(l: sl, r: sr, frames: frames)
            var po: Float = 0
            for f in 0..<frames { po = max(po, abs(sl[f]), abs(sr[f])) }
            self.peakIn = max(self.peakIn, pi); self.peakOut = max(self.peakOut, po)
            for f in 0..<frames { o[2 * f] = sl[f]; o[2 * f + 1] = sr[f] }
        }
        guard err == 0, let p = procID else { teardown(); status = "IOProc failed (\(err))"; return }
        err = AudioDeviceStart(aggID, p)
        guard err == 0 else { teardown(); status = "Start failed (\(err))"; return }
        running = true
        status = "Running @ \(Int(fs)) Hz"
    }

    func stop() { teardown(); running = false; status = "Off" }

    private func teardown() {
        if let p = procID, aggID != kAudioObjectUnknown { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { teardown() }
}
