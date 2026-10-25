import Darwin
import Foundation

@testable import Benchmark

final class TemporaryDirectory {
  let directory: String
  init() throws {
    directory = path(NSTemporaryDirectory(), "benchmark-tests-" + UUID().uuidString)
    try privateDirectory(directory)
  }
  func file(_ name: String) -> String { path(directory, name) }
  func write(_ name: String, _ text: String) throws {
    let destination = file(name)
    try FileManager.default.createDirectory(
      atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: destination))
  }
  deinit { try? FileManager.default.removeItem(atPath: directory) }
}
func testSettings(_ root: String = "/tmp") -> RunSettings {
  RunSettings(
    resultsDir: path(root, "Deliverables/Runs"), suitesDir: path(root, "Resources/suites"),
    workdir: root,
    repeatCount: 1, requestTimeoutSeconds: 30, cooldownSeconds: 0, maxOutputTokens: 32, seed: 42)
}
func testTask(_ scorer: JSON = ["type": "exact", "expected": "ok"]) -> BenchmarkTask {
  BenchmarkTask(id: "task", category: "reasoning", prompt: "answer ok", scorer: scorer.object!)
}
func localTarget(_ base: String) -> TargetConfig {
  TargetConfig(
    id: "local-model", inferenceLocation: "local", adapter: "ollama", model: "test-model",
    baseUrl: base, backend: "ollama", quantization: "Q4_K_M", contextWindow: 8192,
    processMatch: "test-nonexistent-backend")
}
struct FixtureRequest: Sendable {
  let method: String
  let path: String
  let body: JSON
  let headers: String
}
struct FixtureResponse: Sendable {
  var status = 200
  var headers: [String: String] = [:]
  var chunks: [(String, Double)] = []
  init(_ json: JSON) { chunks = [(json.serialized(), 0)] }
  init(status: Int = 200, headers: [String: String] = [:], chunks: [(String, Double)]) {
    self.status = status
    self.headers = headers
    self.chunks = chunks
  }
}
/// Real loopback HTTP with controllable chunks, so tests cover URLSession and its timing behavior.
final class FixtureServer: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let group = DispatchGroup()
  private let stopped = Cancellation()
  private let address: sockaddr_in
  let baseURL: String
  init(_ handler: @escaping @Sendable (FixtureRequest) -> FixtureResponse) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    fileDescriptor = descriptor
    guard fileDescriptor >= 0 else { throw posixError("test socket") }
    var reuse: Int32 = 1
    setsockopt(
      fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fileDescriptor, 128) == 0 else {
      close(fileDescriptor)
      throw posixError("test listen")
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        _ = getsockname(descriptor, $0, &size)
      }
    }
    self.address = address
    baseURL = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
    let stopped = stopped
    let group = group
    group.enter()
    DispatchQueue.global().async {
      // Only this thread closes the listener, so accept never sees a descriptor number reused
      // by a parallel test.
      defer {
        close(descriptor)
        group.leave()
      }
      while !stopped.isCancelled {
        let client = accept(descriptor, nil, nil)
        if client < 0 { break }
        if stopped.isCancelled {
          close(client)
          break
        }
        group.enter()
        DispatchQueue.global().async {
          defer {
            close(client)
            group.leave()
          }
          Self.respond(to: client, handler: handler)
        }
      }
    }
  }
  private static func configure(_ client: Int32) {
    var noPipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(
      client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }
  private static func request(from client: Int32) -> FixtureRequest? {
    var data = Data()
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    while data.count < 1024 * 1024 {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return nil }
      data.append(contentsOf: buffer.prefix(count))
      if let end = data.range(of: separator) {
        headerEnd = end
        break
      }
    }
    guard let end = headerEnd else { return nil }
    guard let headers = String(bytes: data[..<end.lowerBound], encoding: .utf8) else { return nil }
    let length =
      headers.components(separatedBy: "\r\n").first {
        $0.lowercased().hasPrefix("content-length:")
      }.flatMap {
        Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces))
      } ?? 0
    guard length <= 1024 * 1024 else { return nil }
    while data.count - end.upperBound < length {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return nil }
      data.append(contentsOf: buffer.prefix(count))
    }
    let requestLine = headers.components(separatedBy: "\r\n")[0].split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    return FixtureRequest(
      method: String(requestLine[0]), path: String(requestLine[1]),
      body: (try? JSON.parse(Data(data[end.upperBound...].prefix(length)))) ?? .null,
      headers: headers)
  }
  private static func send(_ text: String, to client: Int32) -> Bool {
    let bytes = Data(text.utf8)
    return bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
  }
  private static func send(_ response: FixtureResponse, to client: Int32) -> Bool {
    let contentLength = response.chunks.reduce(0) { $0 + $1.0.utf8.count }
    var head = "HTTP/1.1 \(response.status) Test\r\n"
    head += "Content-Length: \(contentLength)\r\nConnection: close\r\n"
    if response.headers["Content-Type"] == nil {
      head += "Content-Type: application/x-ndjson\r\n"
    }
    for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    guard send(head, to: client) else { return false }
    for (chunk, delay) in response.chunks {
      if delay > 0 { Thread.sleep(forTimeInterval: delay) }
      if !send(chunk, to: client) { return false }
    }
    return true
  }
  private static func respond(
    to client: Int32, handler: @Sendable (FixtureRequest) -> FixtureResponse
  ) {
    configure(client)
    guard let request = request(from: client) else { return }
    _ = send(handler(request), to: client)
  }
  func stop() {
    if !stopped.isCancelled {
      stopped.cancel()
      // Wake the blocked accept with a connection; it then sees the cancellation and exits.
      let waker = socket(AF_INET, SOCK_STREAM, 0)
      var address = address
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(waker, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      close(waker)
      _ = group.wait(timeout: .now() + 5)
    }
  }
  deinit { stop() }
}

final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func update(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&stored)
  }
}
