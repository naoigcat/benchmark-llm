import Foundation

/// Compare decimal coefficients and powers without expanding exponents or rounding digits.
func normalizedJSONNumber(_ token: String) -> String {
  let parts = token.lowercased().split(separator: "e")
  let mantissa = parts[0]
  let fractionDigits = mantissa.split(separator: ".").dropFirst().first?.count ?? 0
  let digits = mantissa.utf8.filter { (48...57).contains($0) }.drop(while: { $0 == 48 })
  let coefficient = digits.reversed().drop(while: { $0 == 48 }).reversed()
  guard !coefficient.isEmpty else { return "0" }
  let exponent = addingJSONExponent(
    parts.count > 1 ? String(parts[1]) : "0",
    digits.count - coefficient.count - fractionDigits)
  return (mantissa.hasPrefix("-") ? "-" : "")
    + String(decoding: coefficient, as: UTF8.self) + "e" + exponent
}

/// Underflowing JSON numbers can have exponents larger than Int in magnitude.
private func addingJSONExponent(_ exponent: String, _ offset: Int) -> String {
  func magnitude(_ value: String) -> [Int] {
    let digits = value.utf8.filter { (48...57).contains($0) }.drop(while: { $0 == 48 })
    return digits.isEmpty ? [0] : digits.map { Int($0 - 48) }
  }
  var left = magnitude(exponent)
  var right = magnitude(String(offset))
  var negative = exponent.hasPrefix("-")
  let adding = negative == (offset < 0)
  if !adding
    && (left.count < right.count
      || (left.count == right.count && left.lexicographicallyPrecedes(right)))
  {
    swap(&left, &right)
    negative = offset < 0
  }
  left.reverse()
  right.reverse()
  var result: [Int] = []
  var carry = 0
  for index in 0..<max(left.count, right.count) {
    let digit =
      (index < left.count ? left[index] : 0)
      + (index < right.count ? right[index] * (adding ? 1 : -1) : 0) + carry
    result.append((digit + 10) % 10)
    carry = digit < 0 ? -1 : digit / 10
  }
  if carry > 0 { result.append(carry) }
  while result.count > 1 && result.last == 0 { result.removeLast() }
  return (negative && result != [0] ? "-" : "") + result.reversed().map(String.init).joined()
}
