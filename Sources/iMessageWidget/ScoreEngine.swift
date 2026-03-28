import Foundation

struct ScoreEngine {

    // MARK: - Time Decay (0–50)
    // Reaches 50 at exactly 2 weeks (336 hours). Logarithmic curve.
    // Formula: min(50, 50 × log10(1 + hours) / log10(337))

    static func timeScore(receivedAt: Date) -> Double {
        let hours = Date().timeIntervalSince(receivedAt) / 3600.0
        guard hours > 0 else { return 0 }
        let score = 50.0 * log10(1.0 + hours) / log10(337.0)
        return min(50.0, score)
    }

    // MARK: - Momentum Score (0–5)
    // Active back-and-forth in last 2h user dropped → +5
    // Active exchange in last 24h user dropped → +3
    // Cold message → +0

    static func momentumScore(handleId: String) -> Double {
        let reader = ChatDBReader.shared
        let last2h  = reader.recentSentMessageCount(handleId: handleId, withinHours: 2)
        let last24h = reader.recentSentMessageCount(handleId: handleId, withinHours: 24)

        if last2h >= 2  { return 5.0 }
        if last24h >= 2 { return 3.0 }
        return 0.0
    }

    // MARK: - Dynamic Score (0–75)

    static func dynamicScore(timeScore: Double, contentScore: Double, momentumScore: Double) -> Double {
        return min(75.0, timeScore + contentScore + momentumScore)
    }

    // MARK: - Effective Score (0–100)

    static func effectiveScore(dynamicScore: Double, priorityAddend: Double) -> Double {
        return min(100.0, dynamicScore + priorityAddend)
    }

    // MARK: - Full Recalculation for a Message

    struct RecalcResult {
        var timeScore: Double
        var dynamicScore: Double
        var effectiveScore: Double
    }

    static func recalculate(message: AppMessage, priorityAddend: Double) -> RecalcResult {
        let t = timeScore(receivedAt: message.receivedAt)
        let d = dynamicScore(timeScore: t, contentScore: message.contentScore, momentumScore: message.momentumScore)
        let e = effectiveScore(dynamicScore: d, priorityAddend: priorityAddend)
        return RecalcResult(timeScore: t, dynamicScore: d, effectiveScore: e)
    }
}
