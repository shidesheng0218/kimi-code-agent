import Foundation

public enum AssistantReplySanitizer {
  /// Sanitizes a complete assistant transcript before it is committed to the conversation.
  /// Streaming callers should pass the accumulated turn text, not an individual token/chunk.
  public static func finalConversationText(from rawText: String, contentType: String? = nil) -> String? {
    if contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "thinking" {
      return nil
    }
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let concise = conciseConversationReply(from: trimmed, contentType: contentType) {
      return concise
    }
    if looksLikeEnglishLeadIn(trimmed) || looksLikeInternalEnglishPreamble(trimmed) || looksLikeAnalysisTranscript(trimmed) {
      return nil
    }
    return visibleText(from: rawText, contentType: contentType)
  }

  public static func visibleText(from rawText: String, contentType: String? = nil) -> String? {
    sanitize(rawText, contentType: contentType, aggressive: false)
  }

  public static func conciseConversationReply(from rawText: String, contentType: String? = nil) -> String? {
    sanitize(rawText, contentType: contentType, aggressive: true)
  }

  private static func sanitize(_ rawText: String, contentType: String?, aggressive: Bool) -> String? {
    if contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "thinking" {
      return nil
    }

    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let reply = bestVisibleReply(in: trimmed, aggressive: aggressive) {
      return reply
    }

    return aggressive ? nil : rawText
  }

  private static func bestVisibleReply(in text: String, aggressive: Bool) -> String? {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let paragraphs = normalized
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    if paragraphs.count > 1 {
      // A normal streamed reply can legitimately contain multiple short paragraphs
      // (for example a title followed by a fetched-page excerpt). Keep the whole
      // reply unless it actually looks like the model's analysis transcript.
      if !looksLikeEnglishLeadIn(normalized),
         !looksLikeInternalEnglishPreamble(normalized),
         !looksLikeAnalysisTranscript(normalized) {
        return removeTrailingInternalNotes(stripToChineseLead(normalized))
      }
      for paragraph in paragraphs.reversed() {
        if looksLikeAnalysisTranscript(paragraph),
           let quotedReply = finalQuotedChineseReply(in: paragraph) {
          return quotedReply
        }
        if let answerSection = answerSection(in: paragraph) {
          return answerSection
        }
        if let candidate = conciseParagraphReply(in: paragraph, aggressive: aggressive) {
          return candidate
        }
      }
    }

    if looksLikeEnglishLeadIn(normalized) || looksLikeInternalEnglishPreamble(normalized) || looksLikeAnalysisTranscript(normalized) {
      if let quotedReply = finalQuotedChineseReply(in: normalized) {
        return quotedReply
      }
      if let answerSection = answerSection(in: normalized) {
        return answerSection
      }
      return cleanTrailingAnalysis(from: stripToChineseLead(normalized))
    }

    if let candidate = conciseParagraphReply(in: normalized, aggressive: aggressive) {
      return candidate
    }

    return nil
  }

  private static func answerSection(in text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard containsChinese(trimmed) else { return nil }

    let markers = [
      "关于这个桌面版能做什么",
      "这个桌面版能做",
      "可以做这些",
      "能做这些",
      "能力如下",
      "答案如下",
      "结论：",
      "可以："
    ]

    for marker in markers {
      guard let range = trimmed.range(of: marker) else { continue }
      let candidate = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard isLikelyAnswerSection(candidate) else { continue }
      return removeTrailingInternalNotes(candidate)
    }

    return nil
  }

  private static func isLikelyAnswerSection(_ text: String) -> Bool {
    let bulletCount = text.components(separatedBy: "\n").filter { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.range(of: #"^\d+[\.、]"#, options: .regularExpression) != nil
    }.count
    return bulletCount > 0 || text.contains("：") || text.contains(":")
  }

  private static func removeTrailingInternalNotes(_ text: String) -> String {
    var lines = text
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    while let last = lines.last, isInternalAnalysisLine(last) {
      lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isInternalAnalysisLine(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    return [
      "用户的问题",
      "用户消息",
      "我需要",
      "由于当前模式",
      "这看起来",
      "所以我",
      "我应该",
      "需要中文回复",
      "第一条回复",
      "后续回复"
    ].contains { trimmed.contains($0) }
  }

  private static func conciseParagraphReply(in text: String, aggressive: Bool) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, containsChinese(trimmed) else { return nil }
    if looksLikeAnalysisTranscript(trimmed),
       let quotedReply = finalQuotedChineseReply(in: trimmed) {
      return quotedReply
    }

    let chineseCount = trimmed.unicodeScalars.filter { isChinese($0) }.count
    let latinLetterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
    let maxLength = aggressive ? 220 : 160
    let maxLatin = aggressive ? 40 : 24

    guard chineseCount >= 2, trimmed.count <= maxLength, latinLetterCount <= maxLatin else { return nil }

    return stripToChineseLead(trimmed)
  }

  private static func finalQuotedChineseReply(in text: String) -> String? {
    quotedSegments(in: text)
      .compactMap { conciseQuotedReply($0) }
      .first
  }

  private static func quotedSegments(in text: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var closingQuote: Character?

    let quotePairs: [Character: Character] = [
      "\"": "\"",
      "'": "'",
      "“": "”",
      "‘": "’",
      "「": "」",
      "『": "』"
    ]

    for character in text {
      if let close = closingQuote {
        if character == close {
          let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
          if !candidate.isEmpty {
            segments.append(candidate)
          }
          current = ""
          closingQuote = nil
        } else {
          current.append(character)
        }
      } else if let close = quotePairs[character] {
        closingQuote = close
        current = ""
      }
    }

    return segments
  }

  private static func conciseQuotedReply(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard containsChinese(trimmed) else { return nil }
    guard !isInternalInstructionSnippet(trimmed) else { return nil }
    let chineseCount = trimmed.unicodeScalars.filter { isChinese($0) }.count
    let latinLetterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
    guard chineseCount >= 2, trimmed.count <= 90, latinLetterCount <= 12 else { return nil }
    guard trimmed.contains("。") || trimmed.contains("！") || trimmed.contains("？") || trimmed.contains("收到") || trimmed.contains("可以") else {
      return nil
    }
    return trimmed
  }

  private static func cleanTrailingAnalysis(from text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let analysisMarkers = [
      " No tools needed",
      " The user ",
      " I should ",
      " According to ",
      " Maybe ",
      " Let's think "
    ]
    for marker in analysisMarkers {
      if let range = value.range(of: marker) {
        value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return value
  }

  private static func isInternalInstructionSnippet(_ text: String) -> Bool {
    [
      "第一条回复",
      "不要解释",
      "不要复述",
      "内部规则",
      "系统提示",
      "后续回复",
      "当前上下文",
      "执行边界"
    ].contains { text.contains($0) }
  }

  private static func stripToChineseLead(_ text: String) -> String {
    guard let firstChinese = firstChineseCharacterIndex(in: text) else { return text }
    let candidate = String(text[firstChinese...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? text : candidate
  }

  private static func looksLikeInternalEnglishPreamble(_ text: String) -> Bool {
    let head = String(text.prefix(260)).lowercased()
    let startsLikeReasoning = [
      "the user",
      "i should",
      "i need",
      "i will",
      "we should",
      "we need",
      "no tools needed"
    ].contains { head.hasPrefix($0) }

    if startsLikeReasoning { return true }
    return head.contains("the user") &&
      (head.contains("i should") || head.contains("no tools needed") || head.contains("respond"))
  }

  private static func looksLikeEnglishLeadIn(_ text: String) -> Bool {
    guard containsChinese(text) else { return false }
    let head = String(text.prefix(120)).lowercased()
    return [
      "sure",
      "okay",
      "ok",
      "yes",
      "certainly",
      "of course",
      "absolutely",
      "alright",
      "let me",
      "here's",
      "here is",
      "i can",
      "i'll",
      "i will",
      "got it",
      "好的",
      "当然",
      "收到"
    ].contains { head.hasPrefix($0) }
  }

  private static func looksLikeAnalysisTranscript(_ text: String) -> Bool {
    let head = String(text.prefix(320))
    return [
      "The user is asking",
      "The user is saying",
      "According to the context",
      "I should respond",
      "I should just say",
      "I have desktop operation tools",
      "Maybe the correct interpretation",
      "Let's think",
      "The instruction says",
      "Short confirmation:",
      "Then explain:",
      "The user wants me to",
      "用户只是",
      "用户的问题",
      "用户消息",
      "这是一个简单的对话问题",
      "不需要使用工具",
      "这看起来",
      "我应该",
      "我需要",
      "根据系统要求",
      "根据指示",
      "所以结论是",
      "因此",
      "这是一个",
      "我可以直接",
      "需要直接回答",
      "我只需要"
    ].contains { head.contains($0) }
  }

  private static func containsChinese(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isChinese)
  }

  private static func isChinese(_ scalar: UnicodeScalar) -> Bool {
    (0x4E00...0x9FFF).contains(scalar.value)
  }

  private static func firstChineseCharacterIndex(in text: String) -> String.Index? {
    text.firstIndex { character in
      character.unicodeScalars.contains { scalar in
        isChinese(scalar)
      }
    }
  }
}
