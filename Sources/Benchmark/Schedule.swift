import Foundation

let shuffleAlgorithm = "splitmix64-fisher-yates-v1"
let maximumScheduledTrials = 1_000_000
struct ScheduleItem: Equatable {
  var target: Int
  var task: Int
  var repeatNumber: Int
  var condition: String
}

func buildSchedule(
  targets: [TargetConfig], taskCount: Int, repeatCount: Int, conditions: [String], seed: UInt64
) throws -> [ScheduleItem] {
  try require(
    repeatCount > 0 && taskCount > 0 && !targets.isEmpty,
    "schedule requires targets, tasks, and a positive repeat count")
  let count = targets.reduce(0) { $0 + $1.cacheConditions(conditions).count }
  let (first, overflow1) = count.multipliedReportingOverflow(by: taskCount)
  let (total, overflow2) = first.multipliedReportingOverflow(by: repeatCount)
  try require(
    !overflow1 && !overflow2 && total <= maximumScheduledTrials,
    "scheduled trials exceeds the supported maximum of \(maximumScheduledTrials)")
  var schedule: [ScheduleItem] = []
  schedule.reserveCapacity(total)
  for repeatNumber in 1...repeatCount {
    for task in 0..<taskCount {
      for (target, config) in targets.enumerated() {
        for condition in config.cacheConditions(conditions) {
          schedule.append(
            ScheduleItem(
              target: target, task: task, repeatNumber: repeatNumber, condition: condition))
        }
      }
    }
  }
  var rng = SeededRandomNumberGenerator(seed: seed)
  if schedule.count > 1 {
    for index in stride(from: schedule.count - 1, through: 1, by: -1) {
      schedule.swapAt(index, rng.index(below: UInt64(index + 1)))
    }
  }
  return schedule
}

/// SplitMix64 provides deterministic random values for reproducible trial scheduling.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  mutating func index(below bound: UInt64) -> Int {
    // Discard the uneven remainder so every position has the same probability.
    let threshold = (0 &- bound) % bound
    while true {
      let value = next()
      if value >= threshold { return Int(value % bound) }
    }
  }
}
