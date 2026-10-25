import Darwin
import Foundation

func posixError(_ operation: String) -> BenchmarkError {
  BenchmarkError("\(operation): \(String(cString: strerror(errno)))")
}

func privateDirectory(_ directory: String) throws {
  if mkdir(directory, 0o700) != 0 {
    if errno == ENOENT {
      try privateDirectory(URL(fileURLWithPath: directory).deletingLastPathComponent().path)
      if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw posixError("mkdir \(directory)") }
    } else if errno != EEXIST {
      throw posixError("mkdir \(directory)")
    }
  }
  let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else { throw posixError("open private directory \(directory)") }
  defer { close(descriptor) }
  var info = stat()
  guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else {
    throw BenchmarkError("private directory belongs to another user: \(directory)")
  }
  guard fchmod(descriptor, 0o700) == 0 else { throw posixError("chmod \(directory)") }
}

func writeAll(_ data: Data, to descriptor: Int32, label: String) throws {
  try data.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = write(
        descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      if written < 0 && errno == EINTR { continue }
      guard written > 0 else { throw posixError("write \(label)") }
      offset += written
    }
  }
}

func atomicWrite(
  _ data: Data, to destination: String, mode: mode_t = 0o644, keepRecovery: Bool = false
) throws {
  let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
  let temporary = path(parent, ".tmp-" + UUID().uuidString)
  let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
  guard descriptor >= 0 else { throw posixError("create \(temporary)") }
  defer {
    close(descriptor)
    if !keepRecovery { unlink(temporary) }
  }
  do {
    try writeAll(data, to: descriptor, label: destination)
    guard fchmod(descriptor, mode) == 0 else { throw posixError("chmod \(destination)") }
    guard fsync(descriptor) == 0 else { throw posixError("sync \(destination)") }
    guard rename(temporary, destination) == 0 else { throw posixError("publish \(destination)") }
    try syncDirectory(parent)
  } catch {
    throw BenchmarkError(
      "\(error)"
        + (keepRecovery && FileManager.default.fileExists(atPath: temporary)
          ? "; recovery file kept at \(temporary)" : ""))
  }
}

func writeJSON(_ value: JSON, to destination: String, mode: mode_t = 0o644) throws {
  try atomicWrite(
    Data((value.serialized(pretty: true) + "\n").utf8), to: destination, mode: mode,
    keepRecovery: true)
}

func syncDirectory(_ directory: String) throws {
  let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard descriptor >= 0 else { throw posixError("open directory for sync") }
  defer { close(descriptor) }
  guard fsync(descriptor) == 0 else { throw posixError("sync directory") }
}

func readJSON(_ source: String) throws -> JSON {
  try JSON.parse(Data(contentsOf: URL(fileURLWithPath: source)))
}

/// Lifetime-bound flock. O_NOFOLLOW prevents a substituted lock from reaching another file.
final class FileLock {
  let fileDescriptor: Int32
  init(_ file: String, directory: Bool = false) throws {
    // Validate a local descriptor first: once the property is set, a throw also runs deinit.
    let descriptor = open(
      file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : O_CREAT), 0o600)
    guard descriptor >= 0 else { throw posixError("open lock \(file)") }
    var info = stat()
    let failure: BenchmarkError? =
      if fstat(descriptor, &info) != 0 {
        posixError("inspect lock \(file)")
      } else if !directory && (info.st_mode & S_IFMT) != S_IFREG {
        BenchmarkError("lock is not a regular file: \(file)")
      } else if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        errno == EWOULDBLOCK
          ? BenchmarkError("another benchmark operation holds the lock: \(file)")
          : posixError("lock \(file)")
      } else {
        nil
      }
    if let failure {
      close(descriptor)
      throw failure
    }
    fileDescriptor = descriptor
  }
  deinit {
    flock(fileDescriptor, LOCK_UN)
    close(fileDescriptor)
  }
}

final class RunLock {
  private let lock: FileLock
  init(_ directory: String) throws {
    // Run outputs are committed and shared between benchmark machines, so their parent directory
    // remains traversable/readable while the lock file itself is still private.
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    lock = try FileLock(path(directory, ".benchmark.lock"))
  }
}

final class Workspace {
  let directory: String
  private let lock: FileLock
  init(root: String) throws {
    try privateDirectory(root)
    directory = path(root, "benchmark-trial-" + UUID().uuidString)
    try privateDirectory(directory)
    lock = try FileLock(directory, directory: true)
  }
  deinit { try? FileManager.default.removeItem(atPath: directory) }
}

func prepareWorkspaceRoot(_ root: String) throws -> String {
  try privateDirectory(root)
  cleanupStaleDirectories(root, prefix: "benchmark-trial-")
  return root
}

func cleanupStaleDirectories(_ root: String, prefix: String) {
  for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
  where name.hasPrefix(prefix) {
    let candidate = path(root, name)
    var info = stat()
    guard lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == geteuid(),
      Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= 86400,
      let lock = try? FileLock(candidate, directory: true)
    else { continue }
    var locked = stat()
    if fstat(lock.fileDescriptor, &locked) == 0
      && locked.st_dev == info.st_dev && locked.st_ino == info.st_ino
    {
      try? FileManager.default.removeItem(atPath: candidate)
    }
    withExtendedLifetime(lock) {}
  }
}

func isWithin(_ child: String, _ root: String) -> Bool {
  root == "/" ? child.hasPrefix("/") : child == root || child.hasPrefix(root + "/")
}
