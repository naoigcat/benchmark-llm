import Foundation

/// JSONDecoder accepts integral floating-point tokens as Int64. Parsing the numeric lexeme here
/// retains the original number kind, which matters for exact-text scorers and integer validation.
struct JSONParser {
  private let decoder = JSONDecoder()
  private let bytes: [UInt8]
  private var cursor = 0
  init(_ data: Data) { bytes = Array(data) }
  init(bytes: [UInt8], offset: Int) {
    self.bytes = bytes
    cursor = offset
  }
  var position: Int { cursor }
  mutating func prefixValue() throws -> JSON { try value(depth: 0) }
  mutating func parse() throws -> JSON {
    let value = try value(depth: 0)
    whitespace()
    try require(cursor == bytes.count, "trailing characters in JSON")
    return value
  }
  private mutating func whitespace() {
    while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
  }
  private mutating func take(_ byte: UInt8) -> Bool {
    if cursor < bytes.count && bytes[cursor] == byte {
      cursor += 1
      return true
    }
    return false
  }
  private mutating func arrayValue(depth: Int) throws -> JSON {
    cursor += 1
    whitespace()
    var values: [JSON] = []
    if take(93) { return .array(values) }
    while true {
      values.append(try value(depth: depth + 1))
      whitespace()
      if take(93) { return .array(values) }
      try require(take(44), "expected comma in JSON array")
    }
  }
  private mutating func objectValue(depth: Int) throws -> JSON {
    cursor += 1
    whitespace()
    var members: [Data: JSONMember] = [:]
    if take(125) { return [:] }
    while true {
      whitespace()
      let key = try string()
      whitespace()
      try require(take(58), "expected colon in JSON object")
      let member = JSONMember(key: key, value: try value(depth: depth + 1))
      try require(
        members.updateValue(member, forKey: Data(key.utf8)) == nil, "duplicate key in JSON object")
      whitespace()
      if take(125) {
        let object = Dictionary(
          members.values.map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new })
        return object.count == members.count
          ? .object(object) : .scalarObject(Array(members.values))
      }
      try require(take(44), "expected comma in JSON object")
    }
  }
  private mutating func value(depth: Int) throws -> JSON {
    try require(depth < 128, "JSON nesting limit exceeded")
    whitespace()
    try require(cursor < bytes.count, "unexpected end of JSON")
    switch bytes[cursor] {
    case 34: return .string(try string())
    case 91: return try arrayValue(depth: depth)
    case 123: return try objectValue(depth: depth)
    case 110:
      try literal("null")
      return .null
    case 116:
      try literal("true")
      return .bool(true)
    case 102:
      try literal("false")
      return .bool(false)
    default: return try number()
    }
  }
  private mutating func literal(_ text: String) throws {
    let end = cursor + text.utf8.count
    try require(
      end <= bytes.count && bytes[cursor..<min(end, bytes.count)].elementsEqual(text.utf8),
      "invalid JSON literal")
    cursor = end
  }
  private mutating func string() throws -> String {
    let start = cursor
    try require(take(34), "expected JSON string")
    var escape = false
    var hasEscape = false
    while cursor < bytes.count {
      let byte = bytes[cursor]
      cursor += 1
      if escape {
        escape = false
      } else if byte == 92 {
        escape = true
        hasEscape = true
      } else if byte == 34 {
        if !hasEscape {
          // String(bytes:encoding:) strips a leading U+FEFF; String(validating:as:) keeps it.
          guard let value = String(validating: bytes[(start + 1)..<(cursor - 1)], as: UTF8.self)
          else { throw BenchmarkError("JSON string is not valid UTF-8") }
          return value
        }
        return try decoder.decode(String.self, from: Data(bytes[start..<cursor]))
      } else {
        try require(byte >= 32, "control character in JSON string")
      }
    }
    throw BenchmarkError("unterminated JSON string")
  }
  private func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
  private mutating func integerPart() throws {
    if !take(48) {
      try require(cursor < bytes.count && (49...57).contains(bytes[cursor]), "invalid JSON number")
      while cursor < bytes.count && digit(bytes[cursor]) { cursor += 1 }
    }
  }
  private mutating func fractionPart() throws -> Bool {
    guard take(46) else { return false }
    let begin = cursor
    while cursor < bytes.count && digit(bytes[cursor]) { cursor += 1 }
    try require(cursor > begin, "invalid JSON fraction")
    return true
  }
  private mutating func exponentPart() throws -> Bool {
    guard take(101) || take(69) else { return false }
    if !take(43) { _ = take(45) }
    let begin = cursor
    while cursor < bytes.count && digit(bytes[cursor]) { cursor += 1 }
    try require(cursor > begin, "invalid JSON exponent")
    return true
  }
  private mutating func number() throws -> JSON {
    let start = cursor
    _ = take(45)
    try integerPart()
    let hasFraction = try fractionPart()
    let hasExponent = try exponentPart()
    let floating = hasFraction || hasExponent
    guard let token = String(bytes: bytes[start..<cursor], encoding: .utf8) else {
      throw BenchmarkError("invalid JSON number")
    }
    if !floating {
      if token == "-0" { return .number(-0.0, literal: token) }
      if let integer = Int64(token) { return .integer(integer) }
      if let unsigned = UInt64(token) { return .unsigned(unsigned) }
    }
    guard let number = Double(token), number.isFinite else {
      throw BenchmarkError("JSON number out of range")
    }
    return .number(number, literal: token)
  }
}
