import Foundation

/// Orchestrates speaker identification: VAD → embedding → matching.
/// Uses temporal continuity to improve accuracy during short gaps.
final class SpeakerIdentifier: @unchecked Sendable {
    private let database: SpeakerDatabase
    private let vad: any VoiceActivityDetector
    private let embedder: any SpeakerEmbedder

    /// Similarity thresholds for speaker matching.
    private let strongMatchThreshold: Double = 0.85
    private let weakMatchThreshold: Double = 0.75
    private let temporalContinuityThreshold: Double = 0.65

    /// Temporal continuity: last speaker per channel and when they were heard.
    private var lastSpeaker: [Int: (id: UUID, timestamp: Double)] = [:]
    private let temporalWindowSeconds: Double = 5.0

    init(database: SpeakerDatabase, vad: any VoiceActivityDetector, embedder: any SpeakerEmbedder) {
        self.database = database
        self.vad = vad
        self.embedder = embedder
    }

    /// Identifies the speaker for an audio segment.
    /// Returns the speaker ID and their display name.
    func identify(
        audio: [Float],
        sampleRate: Double,
        channel: Int,
        timestamp: Double
    ) throws -> (id: UUID, displayName: String)? {
        // 1. Check for voice activity
        guard vad.containsSpeech(audio: audio, sampleRate: sampleRate) else {
            return nil
        }

        // 2. Extract speaker embedding
        let embedding = try embedder.extractEmbedding(audio: audio, sampleRate: sampleRate)

        // 3. Find best match in database
        let match = try database.findMatch(for: embedding, threshold: weakMatchThreshold)

        // 4. Apply temporal continuity
        let speakerID: UUID
        let similarity: Double

        if let match {
            speakerID = match.speakerID
            similarity = match.similarity
        } else if let last = lastSpeaker[channel],
                  timestamp - last.timestamp < temporalWindowSeconds {
            // Check if it might still be the same speaker with lower threshold
            let samples = try database.allSamplesWithEmbeddings()
            let lastSpeakerSamples = samples.filter { $0.speakerID == last.id }
            let bestSimilarity = lastSpeakerSamples.map { cosineSimilarity(embedding, $0.embedding) }.max() ?? 0

            if bestSimilarity > temporalContinuityThreshold {
                speakerID = last.id
                similarity = bestSimilarity
            } else {
                // New speaker
                speakerID = try createNewSpeaker(embedding: embedding, channel: channel)
                similarity = 1.0
            }
        } else {
            // No match and no temporal continuity - new speaker
            speakerID = try createNewSpeaker(embedding: embedding, channel: channel)
            similarity = 1.0
        }

        // 5. Store sample if it's a good match (don't pollute with weak matches)
        if similarity > strongMatchThreshold || similarity == 1.0 {
            _ = try database.addSample(
                embedding: embedding,
                channel: channel,
                speakerID: speakerID,
                confidence: similarity
            )
        }

        // 6. Update temporal state
        lastSpeaker[channel] = (speakerID, timestamp)

        // 7. Get display name
        let name = try database.speakerName(for: speakerID)
        let displayName = name ?? String(speakerID.uuidString.prefix(8).lowercased())

        return (speakerID, displayName)
    }

    private func createNewSpeaker(embedding: [Float], channel: Int) throws -> UUID {
        let speakerID = try database.createSpeaker()
        _ = try database.addSample(
            embedding: embedding,
            channel: channel,
            speakerID: speakerID,
            confidence: 1.0
        )
        return speakerID
    }
}

// MARK: - Voice Activity Detection Protocol

/// Protocol for voice activity detection.
protocol VoiceActivityDetector: Sendable {
    /// Returns true if the audio segment contains speech.
    func containsSpeech(audio: [Float], sampleRate: Double) -> Bool
}

// MARK: - Speaker Embedding Protocol

/// Protocol for extracting speaker embeddings from audio.
protocol SpeakerEmbedder: Sendable {
    /// Extracts a speaker embedding (192-dim vector) from audio.
    func extractEmbedding(audio: [Float], sampleRate: Double) throws -> [Float]
}

// MARK: - Placeholder Implementations

/// Placeholder VAD that always returns true (speech detected).
/// Replace with Silero VAD Core ML implementation.
final class PlaceholderVAD: VoiceActivityDetector {
    func containsSpeech(audio: [Float], sampleRate: Double) -> Bool {
        // TODO: Replace with actual Silero VAD
        // For now, check if audio has any significant energy
        let energy = audio.reduce(0) { $0 + $1 * $1 } / Float(max(audio.count, 1))
        return energy > 0.0001
    }
}

/// Placeholder embedder that generates random embeddings.
/// Replace with ECAPA-TDNN Core ML implementation.
final class PlaceholderEmbedder: SpeakerEmbedder {
    func extractEmbedding(audio: [Float], sampleRate: Double) throws -> [Float] {
        // TODO: Replace with actual ECAPA-TDNN
        // For now, generate a deterministic "embedding" based on audio characteristics
        // This is NOT a real speaker embedding - just a placeholder for testing
        var embedding = [Float](repeating: 0, count: 192)

        // Use audio statistics as pseudo-embedding (won't actually identify speakers)
        let chunkSize = max(1, audio.count / 192)
        for i in 0..<192 {
            let start = i * chunkSize
            let end = min(start + chunkSize, audio.count)
            if start < audio.count {
                let chunk = Array(audio[start..<end])
                embedding[i] = chunk.reduce(0, +) / Float(max(chunk.count, 1))
            }
        }

        // Normalize
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<192 {
                embedding[i] /= norm
            }
        }

        return embedding
    }
}

// MARK: - Cosine Similarity (duplicate for this file, consider moving to shared)

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }

    var dotProduct: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    for i in 0..<a.count {
        dotProduct += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }

    let denominator = sqrt(normA) * sqrt(normB)
    guard denominator > 0 else { return 0 }

    return Double(dotProduct / denominator)
}
