import Foundation
import IOKit.hid

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x3837, kIOHIDProductIDKey: 0x600A] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
print("manager open:", String(IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)), radix: 16))
guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devs.first else { print("no device"); exit(1) }
print("devices:", devs.count)

var buf = [UInt8](repeating: 0, count: 256)
let cb: IOHIDReportCallback = { _, _, _, type, id, rep, len in
    let b = Array(UnsafeBufferPointer(start: rep, count: len))
    print(String(format: "IN  id=0x%02x len=%d  ", id, len) + b.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))
}
IOHIDDeviceRegisterInputReportCallback(dev, &buf, buf.count, cb, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

func send(_ name: String, _ payload: [UInt8]) {
    var out = [UInt8](repeating: 0, count: 64)
    out[0] = 0x55
    for (i, v) in payload.enumerated() { out[1 + i] = v }
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x55, out, out.count)
    print("OUT", name, String(format: "ret=0x%x", r))
    let end = Date().addingTimeInterval(1.0)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
}
for a in CommandLine.arguments.dropFirst() {
    let bytes = a.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    send(a, bytes)
}
