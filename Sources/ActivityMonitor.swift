import Foundation
import Darwin
import IOKit
import IOKit.ps
import SwiftUI
import Metal

struct DataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct ProcessInfoModel: Identifiable {
    let id = UUID()
    let pid: Int32
    let name: String
    let cpu: Double
}

/// Polls system statistics once per second. All mutation happens on the main
/// thread: the timer is scheduled on the main run loop and the two background
/// helpers (`ps` parsing, disk capacity) hop back before publishing.
class ActivityMonitor: ObservableObject {
    @Published var macModel: String = ""
    @Published var gpuName: String = ""
    @Published var localIP: String = "Offline"

    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsage: Double = 0.0
    /// "used/total" for the memory ring, kept short enough not to truncate at
    /// the width the ring gives it.
    @Published var usedMemoryCompact: String = ""

    @Published var appMemoryString: String = ""
    @Published var wiredMemoryString: String = ""
    @Published var compressedMemoryString: String = ""

    @Published var diskUsagePercent: Double = 0.0
    @Published var usedDiskCompact: String = ""
    @Published var diskReadRate: String = "0 KB/s"
    @Published var diskWriteRate: String = "0 KB/s"

    @Published var gpuUsage: Double = 0.0

    @Published var networkUploadRate: String = "0 KB/s"
    @Published var networkDownloadRate: String = "0 KB/s"

    @Published var upTime: String = ""

    @Published var batteryPercent: Double = 0.0
    @Published var batteryIsCharging: Bool = false
    @Published var hasBattery: Bool = false

    @Published var cpuHistory: [DataPoint] = []
    @Published var memoryHistory: [DataPoint] = []
    @Published var gpuHistory: [DataPoint] = []
    @Published var networkHistory: [DataPoint] = []

    @Published var topProcesses: [ProcessInfoModel] = []

    @Published var coreUsages: [Double] = []
    @Published var memoryPressure: String = "Normal"
    @Published var memoryPressureColor: Color = .green

    private let maxHistoryItems = 60

    private var timer: Timer?
    private var previousCpuInfo: host_cpu_load_info?

    private var previousCoreInfos: processor_info_array_t?
    /// Length of `previousCoreInfos` in `integer_t` units — the size needed to
    /// deallocate it. Distinct from `previousProcessorCount`.
    private var previousCoreInfoLength: mach_msg_type_number_t = 0
    /// Number of `processor_cpu_load_info` structs in `previousCoreInfos`.
    private var previousProcessorCount: natural_t = 0

    /// Byte counters from the previous poll, keyed by interface name. Keeping
    /// them per interface means one appearing or disappearing between polls
    /// contributes no delta, rather than dumping its entire lifetime total
    /// into a single second's throughput.
    private var previousInterfaceSent: [String: UInt32] = [:]
    private var previousInterfaceReceived: [String: UInt32] = [:]

    private var previousDiskRead: UInt64 = 0
    private var previousDiskWrite: UInt64 = 0
    private var firstDiskCheck = true

    private var gpuEntries: [io_registry_entry_t] = []
    private var diskEntries: [io_registry_entry_t] = []

    private var tickCount = 0

    init() {
        setupIdentity()
        setupIOKitCaches()
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
        for entry in gpuEntries { IOObjectRelease(entry) }
        for entry in diskEntries { IOObjectRelease(entry) }
        releasePreviousCoreInfos()
    }

    private func setupIdentity() {
        // Mac Model
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var model = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 {
                macModel = String(cString: model)
            }
        }
        if macModel.isEmpty { macModel = "Mac" }

        // GPU Name
        if let device = MTLCopyAllDevices().first {
            gpuName = device.name
        } else {
            gpuName = "Apple GPU"
        }
    }

    private func setupIOKitCaches() {
        var iterator = io_iterator_t()

        // Cache GPU
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess {
            while case let regEntry = IOIteratorNext(iterator), regEntry != 0 {
                gpuEntries.append(regEntry)
            }
            IOObjectRelease(iterator)
        }

        // Cache Disks
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess {
            while case let regEntry = IOIteratorNext(iterator), regEntry != 0 {
                diskEntries.append(regEntry)
            }
            IOObjectRelease(iterator)
        }
    }

    func startMonitoring() {
        if timer != nil { return }
        updateStats()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        // .common keeps the stats flowing while a menu or the popover is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func updateStats() {
        let now = Date()
        tickCount += 1

        cpuUsage = getCPUUsage()
        updateCoreUsages()

        updateMemoryUsage()

        gpuUsage = getGPUUsage()
        updateNetworkUsage(now: now)
        updateDiskIO()

        // Throttle heavy/slow-changing operations
        if tickCount % 4 == 0 {
            updateTopProcesses()
        }
        if tickCount % 5 == 0 {
            updateMemoryPressure()
        }
        if tickCount % 10 == 1 {
            getDiskUsage()
            updateUptime()
            updateBatteryUsage()
        }

        // Add to history every second for smooth graphs
        append(DataPoint(time: now, value: cpuUsage), to: &cpuHistory)
        append(DataPoint(time: now, value: memoryUsage), to: &memoryHistory)
        append(DataPoint(time: now, value: gpuUsage), to: &gpuHistory)
    }

    private func append(_ point: DataPoint, to history: inout [DataPoint]) {
        history.append(point)
        if history.count > maxHistoryItems {
            history.removeFirst(history.count - maxHistoryItems)
        }
    }

    /// Asks a process to exit. The default SIGTERM lets it shut down cleanly;
    /// `force` sends SIGKILL, which cannot be caught and discards any unsaved
    /// work. Direct syscall — no need to spawn /bin/kill.
    func terminateProcess(pid: Int32, force: Bool = false) {
        guard pid > 0 else { return }
        kill(pid, force ? SIGKILL : SIGTERM)
        topProcesses.removeAll { $0.pid == pid }
    }

    private func updateDiskIO() {
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0

        for regEntry in diskEntries {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(regEntry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess {
                if let dict = props?.takeRetainedValue() as? [String: Any],
                   let stats = dict["Statistics"] as? [String: Any] {
                    if let read = stats["Bytes (Read)"] as? NSNumber { readBytes += read.uint64Value }
                    if let write = stats["Bytes (Write)"] as? NSNumber { writeBytes += write.uint64Value }
                }
            }
        }

        defer {
            previousDiskRead = readBytes
            previousDiskWrite = writeBytes
        }

        if firstDiskCheck {
            firstDiskCheck = false
            return
        }

        // A volume disappearing between polls can make the running total drop;
        // an unsigned subtraction there would trap, so clamp instead.
        let readDiff = readBytes >= previousDiskRead ? readBytes - previousDiskRead : 0
        let writeDiff = writeBytes >= previousDiskWrite ? writeBytes - previousDiskWrite : 0

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file

        diskReadRate = formatter.string(fromByteCount: Int64(clamping: readDiff)) + "/s"
        diskWriteRate = formatter.string(fromByteCount: Int64(clamping: writeDiff)) + "/s"
    }

    private func updateMemoryPressure() {
        var pressureLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &size, nil, 0) == 0 {
            switch pressureLevel {
            case 2:
                memoryPressure = "Warning"
                memoryPressureColor = .yellow
            case 4:
                memoryPressure = "Critical"
                memoryPressureColor = .red
            default:
                memoryPressure = "Normal"
                memoryPressureColor = .green
            }
        }
    }

    private func releasePreviousCoreInfos() {
        guard let prev = previousCoreInfos else { return }
        let prevSize = vm_size_t(previousCoreInfoLength) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), prevSize)
        previousCoreInfos = nil
        previousCoreInfoLength = 0
        previousProcessorCount = 0
    }

    private func updateCoreUsages() {
        var numProcessors: natural_t = 0
        var processorInfo: processor_info_array_t?
        var numProcessorInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numProcessors, &processorInfo, &numProcessorInfo)

        guard result == KERN_SUCCESS, let info = processorInfo, numProcessors > 0 else { return }

        let cpuLoadInfo = info.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(numProcessors)) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: Int(numProcessors)))
        }

        var currentCoreUsages: [Double] = []

        if let prevInfo = previousCoreInfos, previousProcessorCount > 0 {
            // Rebind using the *processor* count, not the integer_t length of
            // the buffer — those differ by sizeof(processor_cpu_load_info).
            let prevCount = Int(previousProcessorCount)
            let prevCpuLoadInfo = prevInfo.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: prevCount) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: prevCount))
            }

            for i in 0..<min(Int(numProcessors), prevCount) {
                let current = cpuLoadInfo[i]
                let prev = prevCpuLoadInfo[i]

                let userDiff = Double(current.cpu_ticks.0 &- prev.cpu_ticks.0)
                let sysDiff  = Double(current.cpu_ticks.1 &- prev.cpu_ticks.1)
                let idleDiff = Double(current.cpu_ticks.2 &- prev.cpu_ticks.2)
                let niceDiff = Double(current.cpu_ticks.3 &- prev.cpu_ticks.3)

                let totalTicks = userDiff + sysDiff + idleDiff + niceDiff
                let busyTicks = userDiff + sysDiff + niceDiff

                if totalTicks > 0 {
                    currentCoreUsages.append((busyTicks / totalTicks) * 100.0)
                } else {
                    currentCoreUsages.append(0)
                }
            }
        } else {
            currentCoreUsages = Array(repeating: 0.0, count: Int(numProcessors))
        }

        releasePreviousCoreInfos()

        previousCoreInfos = processorInfo
        previousCoreInfoLength = numProcessorInfo
        previousProcessorCount = numProcessors

        coreUsages = currentCoreUsages
    }

    private func updateBatteryUsage() {
        guard let snapshotRef = IOPSCopyPowerSourcesInfo() else { return }
        let snapshot = snapshotRef.takeRetainedValue()
        guard let sourcesRef = IOPSCopyPowerSourcesList(snapshot) else {
            hasBattery = false
            return
        }
        let sources = sourcesRef.takeRetainedValue() as [CFTypeRef]

        for ps in sources {
            guard let descRef = IOPSGetPowerSourceDescription(snapshot, ps),
                  let info = descRef.takeUnretainedValue() as? [String: Any] else { continue }

            guard let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }

            hasBattery = true
            batteryPercent = (Double(current) / Double(max)) * 100.0
            batteryIsCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            return
        }

        // No source reported a usable capacity — desktop Mac.
        hasBattery = false
    }

    private func updateTopProcesses() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-eo", "pid,pcpu,comm", "-r"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                // Drain before waiting: a full pipe buffer would otherwise
                // deadlock `ps` against `waitUntilExit()`.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                guard let output = String(data: data, encoding: .utf8) else { return }
                let lines = output.split(separator: "\n").dropFirst().prefix(5)
                var top = [ProcessInfoModel]()
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let parts = trimmed.split(separator: " ", maxSplits: 2)
                    if parts.count == 3,
                       let pid = Int32(parts[0]),
                       let cpu = Double(parts[1]) {
                        var name = String(parts[2]).trimmingCharacters(in: .whitespaces)
                        if let lastSlash = name.lastIndex(of: "/") {
                            name = String(name[name.index(after: lastSlash)...])
                        }
                        top.append(ProcessInfoModel(pid: pid, name: name, cpu: cpu))
                    }
                }
                DispatchQueue.main.async {
                    self.topProcesses = top
                }
            } catch { }
        }
    }

    private func updateUptime() {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size

        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return }

        let bootDate = Date(timeIntervalSince1970: Double(bootTime.tv_sec))
        let interval = max(Date().timeIntervalSince(bootDate), 0)

        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if days > 0 {
            upTime = "\(days)d \(hours)h"
        } else {
            upTime = "\(hours)h \(minutes)m"
        }
    }

    private func getCPUUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoadInfo = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }

        if result != KERN_SUCCESS { return 0.0 }
        guard let prev = previousCpuInfo else { previousCpuInfo = cpuLoadInfo; return 0.0 }

        let userDiff = Double(cpuLoadInfo.cpu_ticks.0 &- prev.cpu_ticks.0)
        let sysDiff  = Double(cpuLoadInfo.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idleDiff = Double(cpuLoadInfo.cpu_ticks.2 &- prev.cpu_ticks.2)
        let niceDiff = Double(cpuLoadInfo.cpu_ticks.3 &- prev.cpu_ticks.3)

        previousCpuInfo = cpuLoadInfo

        let totalTicks = userDiff + sysDiff + idleDiff + niceDiff
        let busyTicks = userDiff + sysDiff + niceDiff

        if totalTicks == 0 { return 0.0 }
        return (busyTicks / totalTicks) * 100.0
    }

    private func updateMemoryUsage() {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()

        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }

        var memSize: UInt64 = 0
        var memSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)

        if result != KERN_SUCCESS || memSize == 0 { return }

        let pageSize = UInt64(getpagesize())
        // Widen before subtracting: purgeable_count can briefly exceed
        // internal_page_count, and UInt32 subtraction would trap.
        let internalPages = UInt64(vmStats.internal_page_count)
        let purgeablePages = UInt64(vmStats.purgeable_count)
        let app = (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize

        let usedMemory = app + wired + compressed
        let usagePercent = min((Double(usedMemory) / Double(memSize)) * 100.0, 100.0)

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory

        self.memoryUsage = usagePercent

        let gibibyte = 1024.0 * 1024.0 * 1024.0
        self.usedMemoryCompact = String(format: "%.0f/%.0f GB",
                                        Double(usedMemory) / gibibyte,
                                        Double(memSize) / gibibyte)

        self.appMemoryString = formatter.string(fromByteCount: Int64(clamping: app))
        self.wiredMemoryString = formatter.string(fromByteCount: Int64(clamping: wired))
        self.compressedMemoryString = formatter.string(fromByteCount: Int64(clamping: compressed))
    }

    private func getDiskUsage() {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: "/")
            guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacity else { return }

            let used = max(total - available, 0)
            let usagePercent = (Double(used) / Double(total)) * 100.0

            // Volume capacity is reported in decimal units, matching Finder.
            let gigabyte = 1000.0 * 1000.0 * 1000.0
            let terabyte = 1000.0 * gigabyte
            let compact: String
            if Double(total) >= terabyte {
                compact = String(format: "%.1f/%.0f TB", Double(used) / terabyte, Double(total) / terabyte)
            } else {
                compact = String(format: "%.0f/%.0f GB", Double(used) / gigabyte, Double(total) / gigabyte)
            }

            DispatchQueue.main.async {
                self.diskUsagePercent = usagePercent
                self.usedDiskCompact = compact
            }
        }
    }

    private func getGPUUsage() -> Double {
        var maxUsage = 0.0

        for regEntry in gpuEntries {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(regEntry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess {
                if let serviceDict = properties?.takeRetainedValue() as? [String: AnyObject],
                   let perfStats = serviceDict["PerformanceStatistics"] as? [String: AnyObject] {

                    if let utilization = perfStats["Device Utilization %"] as? NSNumber {
                        maxUsage = max(maxUsage, utilization.doubleValue)
                    } else if let utilization = perfStats["GPU Core Utilization"] as? NSNumber {
                        maxUsage = max(maxUsage, utilization.doubleValue)
                    }
                }
            }
        }
        return min(maxUsage, 100.0)
    }

    private func updateNetworkUsage(now: Date) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }

        var currentSent: [String: UInt32] = [:]
        var currentReceived: [String: UInt32] = [:]
        var foundIP: String?

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            // ifa_addr is null for some interfaces; dereferencing it would crash.
            guard let addr = interface.ifa_addr else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }

            // Get IO bytes
            if addr.pointee.sa_family == UInt8(AF_LINK), let ifaData = interface.ifa_data {
                let data = ifaData.assumingMemoryBound(to: if_data.self)
                currentSent[name] = data.pointee.ifi_obytes
                currentReceived[name] = data.pointee.ifi_ibytes
            }
            // Get IP address
            if foundIP == nil, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if ip != "127.0.0.1" && !ip.isEmpty {
                        foundIP = ip
                    }
                }
            }
        }
        freeifaddrs(ifaddr)

        localIP = foundIP ?? "Offline"

        // Only interfaces present in both samples contribute a delta. Kernel
        // counters are 32-bit and wrap, so &- stays correct across a wrap.
        var sentDiff: UInt32 = 0
        var receivedDiff: UInt32 = 0
        for (name, bytes) in currentSent {
            if let previous = previousInterfaceSent[name] { sentDiff &+= bytes &- previous }
        }
        for (name, bytes) in currentReceived {
            if let previous = previousInterfaceReceived[name] { receivedDiff &+= bytes &- previous }
        }

        previousInterfaceSent = currentSent
        previousInterfaceReceived = currentReceived

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file

        networkUploadRate = formatter.string(fromByteCount: Int64(sentDiff)) + "/s"
        networkDownloadRate = formatter.string(fromByteCount: Int64(receivedDiff)) + "/s"

        let totalKbps = (Double(sentDiff) + Double(receivedDiff)) / 1024.0
        append(DataPoint(time: now, value: totalKbps), to: &networkHistory)
    }
}
