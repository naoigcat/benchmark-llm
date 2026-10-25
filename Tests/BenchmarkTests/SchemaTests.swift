import Foundation
import Testing

@testable import Benchmark

private struct SchemaValidationError: Error, CustomStringConvertible {
  let path: String
  let message: String
  var description: String { "\(path): \(message)" }
}

private struct JSONSchemaValidator {
  let root: JSON

  func validate(_ value: JSON) throws { try validate(value, against: root, at: "$") }

  private func validate(_ value: JSON, against schema: JSON, at path: String) throws {
    if let reference = schema["$ref"].string {
      guard reference.hasPrefix("#/") else {
        throw SchemaValidationError(
          path: path, message: "unsupported schema reference \(reference)")
      }
      var referenced = root
      for component in reference.dropFirst(2).split(separator: "/") {
        guard let next = referenced.object?[String(component)] else {
          throw SchemaValidationError(path: path, message: "missing schema reference \(reference)")
        }
        referenced = next
      }
      try validate(value, against: referenced, at: path)
    }

    if let schemas = schema["allOf"].array {
      for (index, child) in schemas.enumerated() {
        try validate(value, against: child, at: "\(path).allOf[\(index)]")
      }
    }
    if let schemas = schema["oneOf"].array {
      let matches = schemas.filter { (try? validate(value, against: $0, at: path)) != nil }
      guard matches.count == 1 else {
        throw SchemaValidationError(
          path: path, message: "expected exactly one matching oneOf schema, got \(matches.count)")
      }
    }

    if let type = schemaTypes(schema["type"]), !type.contains(where: { matches(value, type: $0) }) {
      throw SchemaValidationError(
        path: path, message: "expected type \(type.joined(separator: ", ")), got \(jsonType(value))"
      )
    }
    if let expected = schema.object?["const"], !value.equivalent(to: expected) {
      throw SchemaValidationError(path: path, message: "does not match const")
    }
    if let values = schema["enum"].array,
      !values.contains(where: { value.equivalent(to: $0) })
    {
      throw SchemaValidationError(path: path, message: "does not match enum")
    }

    guard let members = value.members else {
      try validateArrayAndScalarConstraints(value, schema: schema, path: path)
      return
    }
    if let required = schema["required"].array {
      for key in required.compactMap(\.string)
      where !members.contains(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
        throw SchemaValidationError(path: path, message: "missing required property \(key)")
      }
    }
    let properties = schema["properties"].object ?? [:]
    let additional = schema.object?["additionalProperties"]
    for member in members {
      let key = member.key
      if let propertySchema = properties.first(where: {
        $0.key.utf8.elementsEqual(key.utf8)
      })?.value {
        try validate(member.value, against: propertySchema, at: "\(path).\(key)")
      } else if let additional {
        if additional == false {
          throw SchemaValidationError(path: path, message: "unexpected property \(key)")
        }
        if additional.object != nil {
          try validate(member.value, against: additional, at: "\(path).\(key)")
        }
      }
    }
    try validateArrayAndScalarConstraints(value, schema: schema, path: path)
  }

  private func validateArrayAndScalarConstraints(
    _ value: JSON, schema: JSON, path: String
  ) throws {
    if let values = value.array {
      if let minimum = schema["minItems"].uint, values.count < minimum {
        throw SchemaValidationError(path: path, message: "has fewer than \(minimum) items")
      }
      if schema["uniqueItems"].bool == true {
        for (index, value) in values.enumerated()
        where values[..<index].contains(where: { value.equivalent(to: $0) }) {
          throw SchemaValidationError(path: path, message: "items are not unique")
        }
      }
      if let itemSchema = schema.object?["items"] {
        for (index, item) in values.enumerated() {
          try validate(item, against: itemSchema, at: "\(path)[\(index)]")
        }
      }
    }
    if let string = value.string {
      if let minimum = schema["minLength"].uint,
        string.unicodeScalars.count < minimum
      {
        throw SchemaValidationError(path: path, message: "is shorter than \(minimum) characters")
      }
      if let pattern = schema["pattern"].string {
        // JSON Schema's ECMAScript `$` does not match before a trailing newline; ICU's does.
        let expression = try NSRegularExpression(
          pattern: pattern.hasSuffix("$") ? pattern.dropLast() + "\\z" : pattern)
        let range = NSRange(string.startIndex..., in: string)
        guard expression.firstMatch(in: string, range: range) != nil else {
          throw SchemaValidationError(path: path, message: "does not match pattern")
        }
      }
      if schema["format"].string == "date-time" && !isDateTime(string) {
        throw SchemaValidationError(path: path, message: "is not an ISO 8601 date-time")
      }
    }
    if let number = value.double {
      if let minimum = schema["minimum"].double, number < minimum {
        throw SchemaValidationError(path: path, message: "is below minimum")
      }
      if let maximum = schema["maximum"].double, number > maximum {
        throw SchemaValidationError(path: path, message: "is above maximum")
      }
      if let minimum = schema["exclusiveMinimum"].double, number <= minimum {
        throw SchemaValidationError(path: path, message: "is not above exclusive minimum")
      }
    }
  }

  private func schemaTypes(_ value: JSON) -> [String]? {
    value.string.map { [$0] } ?? value.array?.compactMap(\.string)
  }

  private func matches(_ value: JSON, type: String) -> Bool {
    switch type {
    case "null": return value == .null
    case "boolean": return value.bool != nil
    case "integer": return value.int != nil || value.uint != nil
    case "number": return value.double != nil
    case "string": return value.string != nil
    case "array": return value.array != nil
    case "object": return value.object != nil
    default: return false
    }
  }

  private func jsonType(_ value: JSON) -> String {
    if value == .null { return "null" }
    if value.bool != nil { return "boolean" }
    if value.int != nil || value.uint != nil { return "integer" }
    if value.double != nil { return "number" }
    if value.string != nil { return "string" }
    if value.array != nil { return "array" }
    return "object"
  }

  private func isDateTime(_ value: String) -> Bool {
    for options in [
      ISO8601DateFormatter.Options.withInternetDateTime,
      [.withInternetDateTime, .withFractionalSeconds],
    ] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if formatter.date(from: value) != nil { return true }
    }
    return false
  }
}

func validateJSONSchema(_ value: JSON, against schema: JSON) throws {
  try JSONSchemaValidator(root: schema).validate(value)
}

@Test func bundledTaskEntriesConformToTaskSchema() throws {
  let schema = try readJSON(path(repositoryRoot, "Resources/schemas/task.schema.json"))
  let directory = path(repositoryRoot, "Resources/suites")
  let files = try FileManager.default.contentsOfDirectory(atPath: directory).sorted().filter {
    $0.hasSuffix(".jsonl")
  }
  var entries = 0
  for file in files {
    let text = try String(contentsOfFile: path(directory, file), encoding: .utf8)
    for rawLine in text.components(separatedBy: "\n") {
      let line = rawLine.trimmed
      if line.isEmpty || line.hasPrefix("#") { continue }
      try validateJSONSchema(try JSON.parse(line), against: schema)
      entries += 1
    }
  }
  // Keep the bundled suite size explicit so adding or removing a task gets reviewed.
  #expect(entries == 54)

  var invalid = try JSON.parse(
    #"{"id":"task","category":"test","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#)
  invalid["id"] = "not valid"
  #expect(throws: (any Error).self) { try validateJSONSchema(invalid, against: schema) }
}

@Test func schemaValidationChecksScalarObjectMembers() throws {
  let schema: JSON = [
    "type": "object", "required": ["name"],
    "properties": ["name": ["type": "string"]], "additionalProperties": false,
  ]
  let canonicallyEquivalentKeys = [
    JSONMember(key: "e\u{301}", value: "first"),
    JSONMember(key: "\u{e9}", value: "second"),
  ]
  let missingRequired = JSON.scalarObject(canonicallyEquivalentKeys)
  #expect(throws: (any Error).self) {
    try validateJSONSchema(missingRequired, against: schema)
  }
  let unexpected = JSON.scalarObject(
    [JSONMember(key: "name", value: "ok")] + canonicallyEquivalentKeys)
  #expect(throws: (any Error).self) {
    try validateJSONSchema(unexpected, against: schema)
  }
}
