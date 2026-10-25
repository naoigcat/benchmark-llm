import Darwin
import Foundation

// Keep stderr and combined diagnostics bounded even when stdout capture is larger.
let processDiagnosticLimit = 64 * 1024
let referenceCLIStdoutLineLimit = 8 * 1024 * 1024
// README's processing-limit table is checked against these values.
let referenceCLIEventByteLimit = 16 * 1024 * 1024
let streamEventLimit = 100_000
let httpResponseByteLimit = 64 * 1024 * 1024
private let maxPipeReadsPerService = 64

final class ProcessOutput {
  private let pipes: ProcessPipes
  private let prompt: Data
  private let captureLimit: Int
  private let onLine: ((String, Double) throws -> Void)?
  private var inputOffset = 0
  private var inputFailed = false
  private var line = Data()
  private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
  private(set) var stdout = Data()
  private(set) var stderr = Data()
  private(set) var stdoutTruncated = false
  var failure: (any Error)?
  /// The whole prompt reached the pipe without EPIPE; a short prompt fits the pipe buffer, so this
  /// cannot tell whether the child actually read it.
  var wroteCompletePrompt: Bool { !inputFailed && inputOffset == prompt.count }

  init(
    pipes: ProcessPipes, input: String?, captureLimit: Int,
    onLine: ((String, Double) throws -> Void)?
  ) {
    self.pipes = pipes
    prompt = Data((input ?? "").utf8)
    self.captureLimit = captureLimit
    self.onLine = onLine
  }

  func servicePipes() {
    writeInput()
    for index in [1, 2] where pipes.descriptors[index][0] >= 0 {
      var reads = 0
      while pipes.descriptors[index][0] >= 0 && reads < maxPipeReadsPerService {
        reads += 1
        let count = read(pipes.descriptors[index][0], &buffer, buffer.count)
        if count == 0 {
          pipes.close(index, 0)
        } else if count > 0 {
          let chunk = Data(buffer.prefix(count))
          if index == 2 {
            stderr.append(chunk.prefix(max(0, processDiagnosticLimit - stderr.count)))
          } else {
            acceptStdout(chunk)
          }
        } else if errno != EAGAIN && errno != EINTR {
          pipes.close(index, 0)
        } else if errno == EAGAIN {
          break
        }
      }
    }
  }

  private func writeInput() {
    if inputOffset >= prompt.count { pipes.close(0, 1) }
    guard failure == nil && pipes.descriptors[0][1] >= 0 else { return }
    let written = prompt.withUnsafeBytes {
      write(
        pipes.descriptors[0][1], $0.baseAddress!.advanced(by: inputOffset),
        min(65536, prompt.count - inputOffset))
    }
    if written > 0 {
      inputOffset += written
    } else if written < 0 && errno != EAGAIN && errno != EINTR {
      inputFailed = true
      pipes.close(0, 1)
    }
  }

  private func acceptStdout(_ chunk: Data) {
    if let onLine, failure == nil {
      line.append(chunk)
      do {
        guard chunk.contains(10) else {
          try require(
            line.count <= referenceCLIStdoutLineLimit,
            "CLI stdout line exceeded \(referenceCLIStdoutLineLimit) bytes")
          return
        }
        while let newline = line.firstIndex(of: 10) {
          let raw = line[..<newline]
          guard raw.count + 1 <= referenceCLIStdoutLineLimit else {
            throw ApiError("CLI stdout line exceeded \(referenceCLIStdoutLineLimit) bytes")
          }
          guard let text = String(data: raw, encoding: .utf8) else {
            throw ApiError("CLI output is not valid UTF-8")
          }
          try onLine(text, monotonicTime())
          line.removeSubrange(...newline)
        }
        try require(
          line.count <= referenceCLIStdoutLineLimit,
          "CLI stdout line exceeded \(referenceCLIStdoutLineLimit) bytes")
      } catch {
        failure = error
        line.removeAll()
      }
    } else if onLine == nil {
      if chunk.count > max(0, captureLimit - stdout.count) { stdoutTruncated = true }
      stdout.append(chunk.prefix(max(0, captureLimit - stdout.count)))
    }
  }

  func finishLines() {
    guard failure == nil, let onLine, !line.isEmpty else { return }
    do {
      guard let text = String(data: line, encoding: .utf8) else {
        throw ApiError("CLI output is not valid UTF-8")
      }
      try onLine(text, monotonicTime())
    } catch { failure = error }
  }
}
