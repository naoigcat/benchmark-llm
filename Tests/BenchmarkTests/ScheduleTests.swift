import Testing

@testable import Benchmark

@Test func seededSchedulesAreReproducibleAndCoverEveryTrial() throws {
  let targets = [
    localTarget("http://127.0.0.1"),
    TargetConfig(id: "cloud", inferenceLocation: "remote", adapter: "cli-agent"),
  ]
  func schedule(_ seed: UInt64) throws -> [ScheduleItem] {
    try buildSchedule(
      targets: targets, taskCount: 2, repeatCount: 3, conditions: ["cold", "warm"], seed: seed)
  }
  let actual = try schedule(42)
  #expect(actual == (try schedule(42)))
  #expect(actual != (try schedule(43)))
  #expect(actual.count == 18)
  let tuples = Set(actual.map { "\($0.target)/\($0.task)/\($0.repeatNumber)/\($0.condition)" })
  #expect(tuples.count == 18)
  for target in targets.indices {
    for task in 0..<2 {
      for repeatNumber in 1...3 {
        for condition in targets[target].cacheConditions(["cold", "warm"]) {
          #expect(tuples.contains("\(target)/\(task)/\(repeatNumber)/\(condition)"))
        }
      }
    }
  }
  #expect(throws: (any Error).self) {
    try buildSchedule(
      targets: targets, taskCount: 10, repeatCount: Int.max, conditions: ["cold"], seed: 1)
  }
}
