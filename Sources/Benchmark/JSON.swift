import CryptoKit
import Foundation

/// Keeps parsed number spellings exact, including integers and fractions above Double precision.
enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case integer(Int64)
  case unsigned(UInt64)
  case number(Double, literal: String? = nil)
  case string(String)
  case array([JSON])
  case object([String: JSON])
  // Swift Dictionary treats canonically equivalent String keys as equal. Preserve the
  // exceptional JSON objects that contain distinct scalar spellings of the same key.
  case scalarObject([JSONMember])

  static func parse(_ data: Data) throws -> JSON {
    var parser = JSONParser(data)
    return try parser.parse()
  }
  static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }
  static func of<T: Encodable>(_ value: T) throws -> JSON {
    try parse(JSONEncoder().encode(value))
  }
  static func value(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
  static func value(_ value: UInt64?) -> JSON { value.map(JSON.unsigned) ?? .null }
  static func value(_ value: Double?) -> JSON { value.map { .number($0) } ?? .null }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
  var object: [String: JSON]? {
    switch self {
    case .object(let value): return value
    case .scalarObject(let members):
      return Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
    default: return nil
    }
  }
  var members: [JSONMember]? {
    switch self {
    case .object(let value): return value.map { JSONMember(key: $0.key, value: $0.value) }
    case .scalarObject(let members): return members
    default: return nil
    }
  }
  var uint: UInt64? {
    switch self {
    case .unsigned(let value): value
    case .integer(let value): UInt64(exactly: value)
    default: nil
    }
  }
  var int: Int64? {
    switch self {
    case .integer(let value): value
    case .unsigned(let value): Int64(exactly: value)
    default: nil
    }
  }
  var double: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .unsigned(let value): Double(value)
    case .number(let value, _): value
    default: nil
    }
  }
  subscript(_ key: String) -> JSON {
    get {
      switch self {
      case .object(let object):
        guard let index = object.index(forKey: key),
          object[index].key.utf8.elementsEqual(key.utf8)
        else { return .null }
        return object[index].value
      case .scalarObject(let members):
        return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value ?? .null
      default:
        return .null
      }
    }
    set {
      if case .object(var object) = self {
        if let index = object.index(forKey: key) {
          let existingKey = object[index].key
          if existingKey.utf8.elementsEqual(key.utf8) {
            object[existingKey] = newValue
            self = .object(object)
            return
          }
          self = .scalarObject(
            object.map { JSONMember(key: $0.key, value: $0.value) }
              + [JSONMember(key: key, value: newValue)])
          return
        }
        object[key] = newValue
        self = .object(object)
        return
      }
      var pairs = members ?? []
      if let index = pairs.firstIndex(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
        pairs[index] = JSONMember(key: key, value: newValue)
      } else {
        pairs.append(JSONMember(key: key, value: newValue))
      }
      let dictionary = Dictionary(
        pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
      self = dictionary.count == pairs.count ? .object(dictionary) : .scalarObject(pairs)
    }
  }
  subscript(_ index: Int) -> JSON {
    guard let values = array, values.indices.contains(index) else { return .null }
    return values[index]
  }
  var truthy: Bool {
    switch self {
    case .null: false
    case .bool(let value): value
    case .string(let value): !value.isEmpty
    case .array(let value): !value.isEmpty
    case .object(let value): !value.isEmpty
    case .scalarObject(let value): !value.isEmpty
    default: double != 0
    }
  }
  var text: String {
    // Keep numeric display and exact-text scoring in their existing shortest Double form.
    if case .number(let value, _) = self { return value.isFinite ? String(value) : "null" }
    return string ?? serialized()
  }

  private var numericText: String? {
    switch self {
    case .integer(let value): String(value)
    case .unsigned(let value): String(value)
    case .number(let value, let literal): value.isFinite ? literal ?? String(value) : nil
    default: nil
    }
  }

  /// Stable key ordering makes records and fingerprints deterministic.
  func serialized(pretty: Bool = false) -> String {
    func render(_ value: JSON, _ level: Int) -> String {
      let indent = String(repeating: "  ", count: level)
      let next = indent + "  "
      func collection(_ parts: [String], _ left: String, _ right: String) -> String {
        guard pretty, !parts.isEmpty else { return left + parts.joined(separator: ",") + right }
        return left + "\n" + next + parts.joined(separator: ",\n" + next) + "\n" + indent + right
      }
      switch value {
      case .null: return "null"
      case .bool(let value): return value ? "true" : "false"
      case .integer(let value): return String(value)
      case .unsigned(let value): return String(value)
      case .number(let value, let literal):
        return value.isFinite ? literal ?? String(value) : "null"
      case .string(let value): return quotedJSON(value)
      case .array(let values): return collection(values.map { render($0, level + 1) }, "[", "]")
      case .object(let object):
        return collection(
          object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
            quotedJSON($0) + (pretty ? ": " : ":") + render(object[$0]!, level + 1)
          }, "{", "}")
      case .scalarObject(let members):
        return collection(
          members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map {
            quotedJSON($0.key) + (pretty ? ": " : ":") + render($0.value, level + 1)
          }, "{", "}")
      }
    }
    return render(self, 0)
  }

  func equivalent(to other: JSON) -> Bool {
    if let leftValue = numericText, let rightValue = other.numericText {
      return normalizedJSONNumber(leftValue) == normalizedJSONNumber(rightValue)
    }
    if let leftValue = array, let rightValue = other.array {
      return leftValue.count == rightValue.count
        && zip(leftValue, rightValue).allSatisfy { $0.equivalent(to: $1) }
    }
    if let leftValue = members, let rightValue = other.members {
      return leftValue.count == rightValue.count
        && leftValue.allSatisfy { member in
          rightValue.first { $0.key.utf8.elementsEqual(member.key.utf8) }.map {
            member.value.equivalent(to: $0.value)
          } ?? false
        }
    }
    if let leftValue = string, let rightValue = other.string {
      return leftValue.utf8.elementsEqual(rightValue.utf8)
    }
    return self == other
  }
  static func == (left: JSON, right: JSON) -> Bool {
    switch (left, right) {
    case (.null, .null): return true
    case (.bool(let leftValue), .bool(let rightValue)): return leftValue == rightValue
    case (.string(let leftValue), .string(let rightValue)):
      return leftValue.utf8.elementsEqual(rightValue.utf8)
    case (.integer(let leftValue), .integer(let rightValue)): return leftValue == rightValue
    case (.unsigned(let leftValue), .unsigned(let rightValue)): return leftValue == rightValue
    case (.integer(let leftValue), .unsigned(let rightValue)),
      (.unsigned(let rightValue), .integer(let leftValue)):
      return UInt64(exactly: leftValue) == rightValue
    case (.number(let leftValue, let leftLiteral), .number(let rightValue, let rightLiteral)):
      guard leftValue.isFinite && rightValue.isFinite else { return leftValue == rightValue }
      return normalizedJSONNumber(leftLiteral ?? String(leftValue))
        == normalizedJSONNumber(rightLiteral ?? String(rightValue))
    case (.array(let leftValue), .array(let rightValue)): return leftValue == rightValue
    default:
      guard let leftValue = left.members, let rightValue = right.members,
        leftValue.count == rightValue.count
      else { return false }
      return leftValue.allSatisfy { member in
        rightValue.first { $0.key.utf8.elementsEqual(member.key.utf8) }?.value == member.value
      }
    }
  }
}

private let jsonHexDigits = Array("0123456789abcdef".utf8)

private func quotedJSON(_ text: String) -> String {
  var bytes: [UInt8] = [34]
  bytes.reserveCapacity(text.utf8.count + 2)
  func appendUnicodeEscape(_ value: UInt32) {
    bytes.append(contentsOf: [92, 117])
    for shift in stride(from: 12, through: 0, by: -4) {
      bytes.append(jsonHexDigits[Int((value >> UInt32(shift)) & 0x0f)])
    }
  }
  var iterator = text.utf8.makeIterator()
  while let byte = iterator.next() {
    switch byte {
    case 8: bytes.append(contentsOf: [92, 98])
    case 9: bytes.append(contentsOf: [92, 116])
    case 10: bytes.append(contentsOf: [92, 110])
    case 12: bytes.append(contentsOf: [92, 102])
    case 13: bytes.append(contentsOf: [92, 114])
    case 0...31: appendUnicodeEscape(UInt32(byte))
    case 34: bytes.append(contentsOf: [92, 34])
    case 92: bytes.append(contentsOf: [92, 92])
    case 226:
      let second = iterator.next()
      let third = iterator.next()
      if second == 128 && third == 168 {
        appendUnicodeEscape(0x2028)
      } else if second == 128 && third == 169 {
        appendUnicodeEscape(0x2029)
      } else {
        bytes.append(byte)
        if let second { bytes.append(second) }
        if let third { bytes.append(third) }
      }
    default: bytes.append(byte)
    }
  }
  bytes.append(34)
  return String(decoding: bytes, as: UTF8.self)
}

struct JSONMember: Sendable, Equatable {
  var key: String
  var value: JSON
  static func == (left: Self, right: Self) -> Bool {
    left.key.utf8.elementsEqual(right.key.utf8) && left.value == right.value
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int64) { self = .integer(value) }
  init(floatLiteral value: Double) { self = .number(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(nilLiteral: ()) { self = .null }
  init(arrayLiteral elements: JSON...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

struct BenchmarkError: Error, CustomStringConvertible, LocalizedError, Sendable {
  let description: String
  init(_ message: String) { description = message }
  var errorDescription: String? { description }
}

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension String {
  var trimmed: String {
    let scalars = unicodeScalars.drop(while: { $0.properties.isWhitespace })
    return String(
      String.UnicodeScalarView(
        scalars.reversed().drop(while: { $0.properties.isWhitespace }).reversed()))
  }
  var caseFolded: String {
    folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }
}

func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
  if !condition() { throw BenchmarkError(message()) }
}

func rejectUnknown(_ object: [String: JSON], _ allowed: [String], _ context: String) throws {
  let unknown = Set(object.keys).subtracting(allowed).sorted()
  try require(unknown.isEmpty, "unknown \(context) fields: \(unknown.joined(separator: ", "))")
}

func strings(_ value: JSON, _ context: String) throws -> [String] {
  guard let values = value.array, values.allSatisfy({ $0.string != nil }) else {
    throw BenchmarkError("\(context) must be a string array")
  }
  return values.compactMap(\.string)
}
