import Foundation

private let credentialToken: NSRegularExpression = {
  let tokens = [
    #"sk-[A-Za-z0-9_-]{20,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#,
    #"github_pat_[A-Za-z0-9_]{20,}"#, #"AIza[0-9A-Za-z_-]{35}"#,
    #"glpat-[A-Za-z0-9_-]{20,}"#, #"xox[baprs]-[0-9A-Za-z-]+"#, #"AKIA[0-9A-Z]{16}"#,
    #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
  ]
  let pattern =
    #"(?:^|[^A-Za-z0-9_-])(?:"# + tokens.joined(separator: "|") + #")(?:$|[^A-Za-z0-9_-])"#
  do {
    return try NSRegularExpression(pattern: pattern)
  } catch {
    preconditionFailure("Invalid credential token pattern: \(error)")
  }
}()

private func sensitiveArgument(_ value: String) -> Bool {
  // Split camelCase (accessToken, GITHUBToken) the same way as snake_case and kebab-case.
  let characters = Array(value.drop(while: { $0 == "-" }))
  var words = ""
  for (index, character) in characters.enumerated() {
    if index > 0, character.isUppercase {
      let previous = characters[index - 1]
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      if previous.isLowercase || previous.isNumber
        || (previous.isUppercase && next?.isLowercase == true)
      {
        words.append("-")
      }
    }
    words.append(character)
  }
  let name = words.lowercased().replacingOccurrences(of: "_", with: "-")
  if [
    "token", "api-key", "apikey", "api-token", "access-token", "session-token", "refresh-token",
    "key", "pat", "bearer", "password", "passwd", "secret", "cookie", "authorization", "auth",
    "credential", "credentials", "client-secret", "access-key", "private-key",
  ].contains(name) {
    return true
  }
  // Prefixed names such as GITHUB_TOKEN, DB_PASSWORD, and x-api-key.
  guard let last = name.split(separator: "-").last, name.contains("-") else { return false }
  return [
    "token", "key", "apikey", "pat", "password", "passwd", "secret", "credential", "credentials",
    "cookie", "authorization", "auth",
  ]
  .contains(String(last))
}

/// Quotes around a label or value. The backslash covers JSON nested in a string, such as
/// `{\"api_key\":\"...\"}` in an API error body.
private let quoteCharacters = CharacterSet(charactersIn: "\"'\\")
/// Quotes and brackets around a word: `"Bearer` in `"Bearer xxx"`.
private let wrapperCharacters = quoteCharacters.union(CharacterSet(charactersIn: "{[(,;"))

/// Every `label=` or `label:` in one word, so compact JSON such as
/// `{"headers":{"Authorization":"Bearer` exposes its inner label, not only `headers`.
private func labels(_ value: String) -> [String] {
  value.indices.filter { value[$0] == "=" || value[$0] == ":" }.map { index in
    let before = value[..<index]
    let start = before.lastIndex(where: { "{[(,;=:".contains($0) }).map(before.index(after:))
    return String(before[(start ?? before.startIndex)...]).trimmingCharacters(in: quoteCharacters)
  }
}

private func sensitiveText(_ value: String) -> Bool {
  let lower = value.lowercased()
  if ["bearer ", "authorization:", "api_key=", "api-key=", "access_token=", "access-token="]
    .contains(where: lower.contains)
  {
    return true
  }
  if labels(value).contains(where: sensitiveArgument) { return true }
  for suffix in value.components(separatedBy: "://").dropFirst() {
    let authority = suffix.prefix(while: { !"/?#".contains($0) })
    // user:password@host, and a token used as the user name (https://glpat-xxx@host).
    if let atIndex = authority.lastIndex(of: "@"), atIndex > authority.startIndex { return true }
    // Query credentials such as ?token=... or &api_key=...
    if let query = suffix.split(separator: "?", maxSplits: 1).dropFirst().first?
      .prefix(while: { $0 != "#" }),
      query.split(separator: "&").contains(where: {
        sensitiveArgument(String($0.prefix(while: { $0 != "=" })))
      })
    {
      return true
    }
  }
  return credentialToken.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    != nil
}

func redactCLIArguments(_ arguments: [String]) -> [String] {
  var redactNext = false
  return arguments.map { argument in
    if redactNext {
      redactNext = argument.lowercased() == "bearer"
      return "<redacted>"
    }
    if let index = argument.firstIndex(of: "="), !argument[..<index].contains("://") {
      let flag = String(argument[..<index])
      let value = String(argument[argument.index(after: index)...])
      if sensitiveText(flag) { return "<redacted>" }
      if sensitiveArgument(flag) || sensitiveText(value) { return flag + "=<redacted>" }
    }
    let bearer = argument.lowercased() == "bearer"
    redactNext = bearer || (argument.hasPrefix("-") && sensitiveArgument(argument))
    return bearer || sensitiveText(argument) ? "<redacted>" : argument
  }
}

private let authorizationSchemes: Set = ["bearer", "basic", "token", "digest", "negotiate"]

/// A sensitive label hides the rest of its line. Values may contain spaces, quotes, escapes, or
/// cookie pairs, and word-by-word tracking kept leaking them; harmless words after the value on
/// the same line are hidden too, by design. A label needs `=` or `:`: diagnostics such as
/// "token limit exceeded" use the same words in prose, so a bare label does not hide the next word.
func redactCLIText(_ text: String) -> String {
  var output = ""
  var word = ""
  var redactNext = false
  var redactLine = false
  var sensitiveName = false
  func flush() {
    guard !word.isEmpty else { return }
    defer { word = "" }
    if redactLine {
      output += "<redacted>"
      return
    }
    let lower = word.lowercased().trimmingCharacters(in: wrapperCharacters)
    let bearer = lower == "bearer"
    // Any scheme after "--header Bearer"-style flags still has its credential next.
    let scheme = redactNext && authorizationSchemes.contains(lower)
    let label = labels(word).contains(where: sensitiveArgument)
    // "password = hunter2" and "password =hunter2" split the label from its separator.
    let separated = sensitiveName && (word.first == "=" || word.first == ":")
    if separated {
      output += word.count == 1 ? word : String(word.prefix(1)) + "<redacted>"
      redactLine = true
    } else if redactNext || bearer || label || sensitiveText(word) {
      output += "<redacted>"
      redactLine = label
      redactNext = bearer || scheme
    } else {
      output += word
      redactNext = word.hasPrefix("-") && sensitiveArgument(word)
    }
    sensitiveName =
      !separated
      && sensitiveArgument(word.trimmingCharacters(in: wrapperCharacters))
  }
  for char in text {
    if char.isWhitespace {
      flush()
      if char.isNewline { redactLine = false }
      output.append(char)
    } else {
      word.append(char)
    }
  }
  flush()
  return output
}
