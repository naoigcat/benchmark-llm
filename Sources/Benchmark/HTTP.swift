import Darwin
import Foundation

struct ApiError: Error, CustomStringConvertible, Sendable {
  var description: String
  var statusCode: Int?
  var providerMetrics: [String: JSON] = [:]
  var isTimeout: Bool
  var isInterrupted: Bool
  init(_ message: String, status: Int? = nil, timeout: Bool = false, interrupted: Bool = false) {
    description = message
    statusCode = status
    isTimeout = timeout
    isInterrupted = interrupted
  }
  var reason: String {
    if isInterrupted { return "interrupted" }
    if isTimeout { return "timeout" }
    switch statusCode {
    case 401, 403: return "authentication_error"
    case 429: return "rate_limited"
    case .some: return "api_error"
    case nil: return "request_error"
    }
  }
}

func requireLoopbackEndpoint(_ value: String) throws {
  guard let url = URLComponents(string: value),
    ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
    let rawHost = url.host, url.url != nil
  else { throw BenchmarkError("endpoint must be a valid HTTP or HTTPS URL: \(value)") }
  let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  if let port = url.port {
    try require((0...65535).contains(port), "endpoint port must be between 0 and 65535")
  }
  var ipv4 = in_addr()
  var ipv6 = in6_addr()
  let isV4 = inet_pton(AF_INET, host, &ipv4) == 1 && UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
  let isV6 =
    inet_pton(AF_INET6, host, &ipv6) == 1
    && withUnsafeBytes(of: &ipv6) { bytes in
      bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
  try require(
    isV4 || isV6,
    "endpoint \(value) must use a loopback host; run the benchmark on the machine running Ollama")
}

/// Delegate callbacks are serialized, and the waiting caller only reads state while holding lock.
/// Streaming callbacks run on that delegate queue; completion signals after the last callback.
private final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let condition = NSCondition()
  var finished = false
  var error: (any Error)?
  var body = Data()
  var pending = Data()
  var status = 0
  var bytes = 0
  let startedAt: Double
  var redirects = 0
  let maximumBytes: Int
  let allowRedirects: Bool
  let onLine: ((Data, Double) throws -> Void)?
  init(onLine: ((Data, Double) throws -> Void)?, maximumBytes: Int, allowRedirects: Bool) {
    startedAt = monotonicTime()
    self.onLine = onLine
    self.maximumBytes = maximumBytes
    self.allowRedirects = allowRedirects
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    condition.lock()
    defer { condition.unlock() }
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // CFNetwork buffers text/plain and unknown MIME types, which would distort TTFT.
    if onLine != nil && (200..<300).contains(status)
      && !["application/x-ndjson", "application/json"].contains(
        response.mimeType?.lowercased() ?? "")
    {
      error = ApiError("streaming response must use application/x-ndjson or application/json")
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    condition.lock()
    defer { condition.unlock() }
    do {
      try require(allowRedirects, "redirected Ollama startup probe")
      try requireLoopbackEndpoint(request.url?.absoluteString ?? "")
      redirects += 1
      try require(redirects <= 10, "too many HTTP redirects")
      completionHandler(request)
    } catch {
      self.error = error
      completionHandler(nil)
      task.cancel()
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    condition.lock()
    defer { condition.unlock() }
    bytes += data.count
    guard error == nil else { return }
    do {
      if !(200..<300).contains(status) {
        body.append(data.prefix(max(0, 65536 - body.count)))
        if body.count >= 65536 {
          self.error = responseError()
          dataTask.cancel()
        }
        return
      }
      try require(bytes <= maximumBytes, "HTTP response exceeded \(maximumBytes) bytes")
      if let onLine {
        pending.append(data)
        while let index = pending.firstIndex(of: 10) {
          try onLine(Data(pending[..<index]), monotonicTime())
          pending.removeSubrange(...index)
        }
      } else {
        body.append(data)
      }
    } catch {
      self.error = error
      dataTask.cancel()
    }
  }
  private func responseError() -> ApiError {
    var detail = String(bytes: body, encoding: .utf8)?.trimmed ?? ""
    if let json = try? JSON.parse(body), json["error"].truthy {
      detail = json["error"]["message"].truthy ? json["error"]["message"].text : json["error"].text
    }
    return ApiError(
      "HTTP \(status)" + (detail.isEmpty ? "" : ": " + String(detail.prefix(500))), status: status)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    condition.lock()
    defer { condition.unlock() }
    if self.error == nil {
      if let error {
        self.error = ApiError(
          // A transport failure after a 2xx header is still a request error, not an API error.
          "request failed: \(error.localizedDescription)",
          status: status == 0 || (200..<300).contains(status) ? nil : status,
          timeout: (error as NSError).code == NSURLErrorTimedOut)
      } else if !(200..<300).contains(status) {
        self.error = responseError()
      } else if !pending.isEmpty {
        do { try onLine?(pending, monotonicTime()) } catch { self.error = error }
      }
    }
    finished = true
    condition.broadcast()
  }
}

private func streamingCallback(
  _ callback: @escaping (JSON, Double) throws -> Void, url: String
) -> (Data, Double) throws -> Void {
  { data, timestamp in
    guard let text = String(data: data, encoding: .utf8) else {
      throw ApiError("invalid streaming UTF-8")
    }
    if text.trimmed.isEmpty { return }
    let event = try JSON.parse(text)
    try require(event.object != nil, "expected streaming object from \(url)")
    try callback(event, timestamp)
  }
}

private func waitForTransfer(
  _ transfer: HTTPTransfer, task: URLSessionDataTask, timeout: Double, cancellation: Cancellation?
) {
  transfer.condition.lock()
  defer { transfer.condition.unlock() }
  while !transfer.finished {
    if cancellation?.isCancelled == true {
      transfer.error = ApiError("HTTP request interrupted", interrupted: true)
      task.cancel()
    } else if transfer.error == nil {
      if monotonicTime() - transfer.startedAt >= timeout {
        transfer.error = ApiError("HTTP request timed out", timeout: true)
        task.cancel()
      }
    }
    _ = transfer.condition.wait(until: Date(timeIntervalSinceNow: 0.02))
  }
}

func httpRequest(
  _ method: String, url: String, payload: JSON? = nil, timeout: Double,
  cancellation: Cancellation? = nil, maximumBytes: Int = httpResponseByteLimit,
  allowRedirects: Bool = true, onLine: ((JSON, Double) throws -> Void)? = nil
) throws -> JSON {
  try requireLoopbackEndpoint(url)
  try require(timeout.isFinite && timeout > 0, "HTTP timeout must be positive and finite")
  let transfer = HTTPTransfer(
    onLine: onLine.map { streamingCallback($0, url: url) }, maximumBytes: maximumBytes,
    allowRedirects: allowRedirects)
  let config = URLSessionConfiguration.ephemeral
  config.connectionProxyDictionary = [:]
  config.httpCookieStorage = nil
  config.urlCredentialStorage = nil
  config.urlCache = nil
  config.timeoutIntervalForRequest = timeout
  config.timeoutIntervalForResource = timeout
  let queue = OperationQueue()
  queue.maxConcurrentOperationCount = 1
  let session = URLSession(configuration: config, delegate: transfer, delegateQueue: queue)
  defer { session.invalidateAndCancel() }
  guard let requestURL = URL(string: url) else {
    throw BenchmarkError("endpoint must be a valid HTTP or HTTPS URL: \(url)")
  }
  var request = URLRequest(url: requestURL)
  request.httpMethod = method
  request.setValue(
    onLine == nil ? "application/json" : "application/x-ndjson, application/json",
    forHTTPHeaderField: "Accept")
  if let payload {
    request.httpBody = Data(payload.serialized().utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  }
  let task = session.dataTask(with: request)
  task.resume()
  waitForTransfer(transfer, task: task, timeout: timeout, cancellation: cancellation)
  if let error = transfer.error { throw error }
  if onLine != nil { return [:] }
  let json = try JSON.parse(transfer.body)
  try require(json.object != nil, "expected an object response from \(url)")
  return json
}
