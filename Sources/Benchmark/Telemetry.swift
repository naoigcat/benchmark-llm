import Darwin
import Foundation

let gibibyte: UInt64 = 1024 * 1024 * 1024
func detectHost() -> JSON {
  let info = ProcessInfo.processInfo
  return [
    "os": .value(commandOutput(["uname", "-s"])),
    "os_version": .value(commandOutput(["sw_vers", "-productVersion"])),
    "architecture": .value(commandOutput(["uname", "-m"])),
    "hardware_model": .value(commandOutput(["sysctl", "-n", "hw.model"])),
    "chip": .value(commandOutput(["sysctl", "-n", "machdep.cpu.brand_string"])),
    "memory_bytes": .unsigned(info.physicalMemory),
    "physical_cpu_count": .value(
      commandOutput(["sysctl", "-n", "hw.physicalcpu"]).flatMap(UInt64.init)),
    "logical_cpu_count": .integer(Int64(info.activeProcessorCount)),
  ]
}

func selectHost(_ hosts: [HostConfig], detected: JSON) throws -> HostConfig {
  guard let chip = detected["chip"].string, !chip.isEmpty else {
    throw BenchmarkError("cannot automatically select a host: chip could not be detected")
  }
  guard let memory = detected["memory_bytes"].uint, memory > 0 else {
    throw BenchmarkError(
      "cannot automatically select a host: physical memory could not be detected")
  }
  let matches = hosts.filter {
    let (bytes, overflow) = $0.memoryGib.multipliedReportingOverflow(by: gibibyte)
    let expected = overflow ? UInt64.max : bytes
    return $0.chip == chip
      && (memory > expected ? memory - expected : expected - memory) <= gibibyte
  }
  if matches.count == 1 { return matches[0] }
  let size = String(format: "%.1f", Double(memory) / Double(gibibyte))
  if matches.isEmpty {
    throw BenchmarkError(
      """
      detected chip '\(chip)' and memory \(size) GiB do not match any hosts entry; update the hosts \
      in the configuration
      """
    )
  }
  throw BenchmarkError(
    """
    detected chip '\(chip)' and memory \(size) GiB match multiple hosts entries: \
    \(matches.map(\.id).joined(separator: ", ")); make the host definitions unambiguous
    """
  )
}

func parseProcessRSS(_ output: String, matching: String) -> UInt64? {
  var sum: UInt64 = 0
  var found = false
  for line in output.components(separatedBy: "\n") {
    let parts = line.trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard parts.count == 2,
      URL(fileURLWithPath: String(parts[1]).trimmed).lastPathComponent.lowercased().contains(
        matching.lowercased()), let rss = UInt64(parts[0])
    else { continue }
    let (new, overflow) = sum.addingReportingOverflow(rss)
    sum = overflow ? .max : new
    found = true
  }
  let (bytes, overflow) = sum.multipliedReportingOverflow(by: 1024)
  return found ? (overflow ? .max : bytes) : nil
}

private func swapUsed() -> UInt64? {
  var usage = xsw_usage()
  var size = MemoryLayout.size(ofValue: usage)
  guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
  return usage.xsu_used
}

private func processIDs() -> [pid_t]? {
  let stride = MemoryLayout<pid_t>.stride
  var bufferSize = 4096 * stride
  for _ in 0..<8 {
    var pids = [pid_t](repeating: 0, count: bufferSize / stride)
    let byteCount = pids.withUnsafeMutableBytes { buffer -> Int32 in
      guard let baseAddress = buffer.baseAddress else { return -1 }
      return proc_listpids(UInt32(PROC_ALL_PIDS), 0, baseAddress, Int32(buffer.count))
    }
    guard byteCount >= 0 else { return nil }
    if Int(byteCount) < bufferSize {
      return pids.prefix(Int(byteCount) / stride).filter { $0 > 0 }
    }
    bufferSize *= 2
  }
  return nil
}

private func processPath(_ pid: pid_t) -> String? {
  var buffer = [CChar](repeating: 0, count: 4096)
  guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
  return buffer.withUnsafeBufferPointer { pointer in
    guard let baseAddress = pointer.baseAddress else { return nil }
    return String(validatingCString: baseAddress)
  }
}

private func processResidentMemory(_ pid: pid_t) -> (rss: UInt64?, error: Int32?) {
  var usage = rusage_info_v4()
  let result = withUnsafeMutablePointer(to: &usage) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
    }
  }
  guard result == 0 else { return (nil, errno) }
  return (usage.ri_resident_size, nil)
}

private struct ProcessRSSMeasurement {
  let bytes: UInt64?
  let matchingProcessFound: Bool
  let unavailable: Bool
}

private func processRSSMeasurement(matching: String) -> ProcessRSSMeasurement {
  guard !matching.isEmpty else {
    return ProcessRSSMeasurement(bytes: nil, matchingProcessFound: false, unavailable: false)
  }
  guard let pids = processIDs() else {
    return ProcessRSSMeasurement(bytes: nil, matchingProcessFound: false, unavailable: true)
  }
  let needle = matching.lowercased()
  var sum: UInt64 = 0
  var found = false
  var permissionDenied = false
  var inspectionFailed = false
  for pid in pids {
    guard let executable = processPath(pid),
      URL(fileURLWithPath: executable).lastPathComponent.lowercased().contains(needle)
    else { continue }
    found = true
    let measurement = processResidentMemory(pid)
    if let rss = measurement.rss {
      let (new, overflow) = sum.addingReportingOverflow(rss)
      sum = overflow ? .max : new
    } else if measurement.error == EPERM {
      permissionDenied = true
    } else if measurement.error != ESRCH {
      inspectionFailed = true
    }
  }
  if permissionDenied {
    // proc_pid_rusage can reject another user's process. One ps snapshot preserves the
    // all-user measurement for this sample without paying the process-spawn cost normally.
    guard let output = commandOutput(["ps", "-axo", "rss=,comm="], timeout: 1),
      let rss = parseProcessRSS(output, matching: matching)
    else {
      return ProcessRSSMeasurement(bytes: nil, matchingProcessFound: true, unavailable: true)
    }
    return ProcessRSSMeasurement(bytes: rss, matchingProcessFound: true, unavailable: false)
  }
  if inspectionFailed {
    return ProcessRSSMeasurement(bytes: nil, matchingProcessFound: found, unavailable: true)
  }
  return ProcessRSSMeasurement(
    bytes: found ? sum : nil, matchingProcessFound: found, unavailable: false)
}

struct MemoryMetrics: Sendable {
  var sampleCount = 0
  var peakRSS: UInt64?
  /// One unreadable sample may have been the peak, so the whole peak becomes unknown.
  var rssUnavailable = false
  var baselineSwap: UInt64?
  var peakSwap: UInt64?
  var swapUnavailable = false
  var json: JSON {
    let peakSwap = swapUnavailable ? nil : peakSwap
    return [
      "memory_sample_count": .integer(Int64(sampleCount)),
      "peak_backend_rss_bytes": .value(rssUnavailable ? nil : peakRSS),
      "baseline_swap_used_bytes": .value(baselineSwap), "peak_swap_used_bytes": .value(peakSwap),
      "peak_swap_delta_bytes": .value(
        peakSwap.flatMap { peak in baselineSwap.map { peak > $0 ? peak - $0 : 0 } }),
    ]
  }
}

/// All mutable samples and the timer are accessed on queue; stop drains it before returning.
final class MemorySampler: @unchecked Sendable {
  private let queue = DispatchQueue(label: "benchmark.memory-sampler")
  private var timer: DispatchSourceTimer?
  private var metrics = MemoryMetrics()
  private let matching: String?
  private let readSwap: () -> UInt64?
  init(matching: String?, readSwap: @escaping () -> UInt64? = swapUsed) {
    self.matching = matching
    self.readSwap = readSwap
  }
  func start() {
    queue.sync {
      guard timer == nil else { return }
      metrics = MemoryMetrics(
        baselineSwap: readSwap())
      metrics.swapUnavailable = metrics.baselineSwap == nil
      sample()
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
      timer.setEventHandler { [weak self] in self?.sample() }
      self.timer = timer
      timer.resume()
    }
  }
  func stop() -> MemoryMetrics {
    queue.sync {
      guard let timer else { return MemoryMetrics() }
      timer.cancel()
      self.timer = nil
      sample()
      return metrics
    }
  }
  private func sample() {
    let rss = matching.map { processRSSMeasurement(matching: $0) }
    let swap = readSwap()
    metrics.sampleCount += 1
    if rss?.unavailable == true { metrics.rssUnavailable = true }
    if swap == nil { metrics.swapUnavailable = true }
    if let bytes = rss?.bytes { metrics.peakRSS = max(metrics.peakRSS ?? 0, bytes) }
    if let swap { metrics.peakSwap = max(metrics.peakSwap ?? 0, swap) }
  }
  deinit { timer?.cancel() }
}

func memoryPreflightWarnings(_ targets: [TargetConfig], host: String) -> [String] {
  let matchers = Set(
    targets.filter { $0.adapter == "ollama" && $0.eligible(on: host) }.compactMap(\.processMatch)
      .filter { !$0.isEmpty }
  ).sorted()
  if matchers.isEmpty { return [] }
  return matchers.compactMap { matcher -> String? in
    let measurement = processRSSMeasurement(matching: matcher)
    if let rss = measurement.bytes {
      return """
        Existing processes matching \(matcher) use \(rss) RSS bytes before startup. Sampling includes all \
        matching processes across users; close unrelated instances before measuring.
        """
    } else if measurement.unavailable {
      return measurement.matchingProcessFound
        ? "Could not measure existing processes matching \(matcher); RSS attribution was not measured."
        : "Could not inspect existing backend processes; RSS attribution was not measured."
    } else {
      return nil
    }
  }
}
