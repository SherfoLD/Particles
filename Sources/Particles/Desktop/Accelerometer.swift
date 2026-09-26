import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

/// Best-effort access to the built-in Apple Silicon MacBook accelerometer.
/// The SPU report format is undocumented; only its known 22-byte format is read.
/// Reference: https://github.com/olvvier/apple-silicon-accelerometer
@MainActor
final class Accelerometer {
    private var device: IOHIDDevice?
    private let reportBuffer = NSMutableData(length: 256)!
    private var watchdog: Timer?
    private var startedAt = 0.0
    private var lastSampleAt: Double?
    private var tilt = SIMD3<Double>(0, 0, -1)
    private var shake = SIMD3<Double>.zero
    private var force = CGVector.zero
    private(set) var failure: String?

    private struct DriverProperty {
        let service: io_service_t
        let key: String
        let previous: CFTypeRef
        let requested: Int
    }
    private var driverProperties: [DriverProperty] = []

    func start() {
        guard device == nil else { return }
        failure = nil
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
            failure = "Sensor unavailable"
            return
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            failure = "Sensor unavailable"
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard Self.isAccelerometer(service), let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                failure = "Sensor access denied or unavailable"
                NSLog("Particles: accelerometer open failed (%d)", result)
                continue
            }
            device = candidate
            failure = nil
            startedAt = ProcessInfo.processInfo.systemUptime
            IOHIDDeviceRegisterInputReportCallback(candidate,
                reportBuffer.mutableBytes.assumingMemoryBound(to: UInt8.self), reportBuffer.length,
                { context, result, _, _, _, report, length in
                    guard result == kIOReturnSuccess, let context else { return }
                    // Scheduled exclusively on the main run loop, including menu tracking.
                    MainActor.assumeIsolated {
                        Unmanaged<Accelerometer>.fromOpaque(context).takeUnretainedValue()
                            .receive(report, length: length)
                    }
                }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(candidate, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            enableReporting()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkStream() }
            }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        if failure == nil { failure = "No supported sensor" }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceRegisterInputReportCallback(device,
                reportBuffer.mutableBytes.assumingMemoryBound(to: UInt8.self), reportBuffer.length, nil, nil)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        for property in driverProperties.reversed() {
            // Avoid overwriting a different setting made by another sensor client.
            let current = IORegistryEntryCreateCFProperty(property.service, property.key as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
            if (current as? NSNumber)?.intValue == property.requested {
                IORegistryEntrySetCFProperty(property.service, property.key as CFString, property.previous)
            }
            IOObjectRelease(property.service)
        }
        driverProperties.removeAll()
        lastSampleAt = nil
        tilt = SIMD3(0, 0, -1)
        shake = .zero
        force = .zero
        failure = nil
    }

    /// Offset from ordinary downward gravity, expressed in g.
    func acceleration(at time: Double) -> CGVector {
        guard device != nil, let lastSampleAt, time - lastSampleAt < 0.25 else { return .zero }
        return force
    }

    private static func isAccelerometer(_ service: io_service_t) -> Bool {
        func value(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        return value("PrimaryUsagePage") == 0xFF00 && value("PrimaryUsage") == 3
    }

    private func enableReporting() {
        // SPU power/reporting properties belong to the driver, not IOHIDDevice.
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard Self.isAccelerometer(service) else { continue }
            for (key, requested) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1),
                                     ("ReportInterval", 10_000)] {
                let previous = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue()
                let result = IORegistryEntrySetCFProperty(service, key as CFString, NSNumber(value: Int32(requested)))
                if result == KERN_SUCCESS, let previous {
                    IOObjectRetain(service)
                    driverProperties.append(DriverProperty(service: service, key: key, previous: previous, requested: requested))
                }
            }
        }
    }

    private func checkStream() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastSampleAt ?? startedAt) > 2 else { return }
        stop()
        failure = "No sensor readings — toggle to retry"
        NSLog("Particles: accelerometer did not deliver readings")
    }

    private func receive(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length == 22 else { return }
        func axis(_ offset: Int) -> Double {
            let bits = UInt32(report[offset]) | UInt32(report[offset + 1]) << 8
                | UInt32(report[offset + 2]) << 16 | UInt32(report[offset + 3]) << 24
            return Double(Int32(bitPattern: bits)) / 65_536
        }
        let sample = SIMD3(axis(6), axis(10), axis(14))
        guard abs(sample.x) <= 16, abs(sample.y) <= 16, abs(sample.z) <= 16 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastSampleAt, now - previous < 0.25 {
            let dt = max(0, now - previous)
            tilt += (sample - tilt) * (1 - exp(-dt / 0.18))
            shake += (sample - tilt - shake) * (1 - exp(-dt / 0.025))
        } else {
            // No startup/wake impulse from the initial gravity measurement.
            if lastSampleAt == nil {
                NSLog("Particles: accelerometer is streaming (initial XYZ: %.3f, %.3f, %.3f g)", sample.x, sample.y, sample.z)
            }
            tilt = sample
            shake = .zero
        }
        lastSampleAt = now
        // Map chassis X to screen X and chassis Y/Z to screen Y. At rest on a
        // level desk Z is -1g. Pitch and roll redirect gravity; faster movement
        // receives extra gain so a gentle shake can lift a settled pile.
        func quiet(_ value: Double) -> Double { abs(value) < 0.015 ? 0 : value }
        let x = quiet(tilt.x) + 3 * quiet(shake.x)
        let y = quiet(tilt.y) + tilt.z + 3 * quiet(shake.y + shake.z)
        force = CGVector(dx: min(4, max(-4, x)), dy: min(4, max(-4, y)) + 1)
    }
}
