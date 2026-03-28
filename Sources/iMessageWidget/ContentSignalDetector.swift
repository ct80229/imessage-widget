import Foundation

struct ContentSignalDetector {

    // MARK: - Question keywords

    private static let questionKeywords: Set<String> = [
        "what", "when", "where", "who", "why", "how", "which", "whose", "whom",
        "can you", "could you", "would you", "will you", "do you", "are you",
        "is it", "have you", "did you", "should i", "can i", "would i"
    ]

    // MARK: - Time-sensitive keywords

    private static let timeSensitiveKeywords: Set<String> = [
        "tonight", "tomorrow", "today", "this morning", "this afternoon", "this evening",
        "urgent", "urgently", "asap", "deadline", "hurry", "quickly", "soon",
        "right now", "immediately", "before", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "this week", "next week",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december"
    ]

    // MARK: - Emotional keywords

    private static let emotionalKeywords: Set<String> = [
        "miss you", "missing you", "worried", "worry", "are you okay", "you okay",
        "need to talk", "we need to talk", "i need you", "please call",
        "scared", "afraid", "anxious", "stressed", "crying", "cry",
        "love you", "i love", "hate", "hurt", "pain", "sad", "depressed",
        "emergency", "bad news", "serious", "important news"
    ]

    // MARK: - Conversational closers

    private static let conversationalClosers: Set<String> = [
        "sounds good", "sounds great", "👍", "lol", "haha", "hahaha", "lmao",
        "ok", "okay", "k", "sure", "no worries", "no problem", "np",
        "got it", "noted", "cool", "nice", "awesome", "yep", "yup",
        "thanks", "thank you", "thx", "ty", "👌", "🙏", "😂", "😆", "🤣"
    ]

    // MARK: - Detection

    func detect(text: String, medianContactMessageLength: Double) -> ContentSignals {
        var signals = ContentSignals()
        let lower = text.lowercased()

        // Question detection
        if text.contains("?") {
            signals.isQuestion = true
        } else {
            for kw in Self.questionKeywords {
                if lower.contains(kw) {
                    signals.isQuestion = true
                    break
                }
            }
        }

        // Time-sensitive detection
        for kw in Self.timeSensitiveKeywords {
            if lower.contains(kw) {
                signals.isTimeSensitive = true
                break
            }
        }
        // Detect specific date patterns (e.g. "3pm", "5:30", "March 15")
        if !signals.isTimeSensitive {
            let timePattern = try? NSRegularExpression(pattern: #"\b\d{1,2}(:\d{2})?\s*(am|pm)\b"#, options: .caseInsensitive)
            if timePattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                signals.isTimeSensitive = true
            }
        }

        // Emotional detection
        for kw in Self.emotionalKeywords {
            if lower.contains(kw) {
                signals.isEmotional = true
                break
            }
        }

        // Conversational closer detection
        let wordCount = text.split(separator: " ").count
        if wordCount <= 6 {   // only check short messages for closers
            for closer in Self.conversationalClosers {
                if lower == closer || lower.contains(closer) {
                    signals.isConversationalCloser = true
                    break
                }
            }
        }

        // Long message detection (> 2x median)
        let threshold = max(10, medianContactMessageLength * 2)
        signals.isLongMessage = Double(wordCount) > threshold

        // Content score calculation
        var score: Double = 0
        if signals.isQuestion        { score += 8 }
        if signals.isTimeSensitive   { score += 6 }
        if signals.isEmotional       { score += 5 }
        if signals.isLongMessage     { score += 3 }
        if signals.isConversationalCloser { score -= 10 }
        signals.contentScore = max(0, min(20, score))

        return signals
    }
}
