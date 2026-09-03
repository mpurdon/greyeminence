import Foundation

/// Turns diarization output into named speakers.
///
/// Sits between the clusterer, which knows voices apart but not who they are,
/// and the contact roster, which knows who was invited but not who spoke.
/// Pure — no audio, no store — so the labelling rules are testable.
enum SpeakerIdentification {
    /// A cluster reduced to a signature, ready to be named.
    struct Cluster {
        let clusterID: String
        let label: String
        let signature: VoiceSignature
    }

    /// What a cluster should be called.
    ///
    /// One optional rather than a match plus a flag: `applied == true` with no
    /// match was representable and meaningless, and callers had to know which
    /// combinations were legal.
    struct Resolution {
        let label: String
        /// The person this voice was confidently recognised as. Nil leaves the
        /// number in place — a near-miss is not carried, because nothing reads
        /// a rejected match.
        let identified: VoiceProfileStore.Match?

        var displayName: String { identified?.profile.contactName ?? label }
    }

    /// One meeting's diarization, resolved into speakers ready to apply.
    ///
    /// Re-processing labels segments as it builds them; the repair pass
    /// relabels segments that already exist. Those are two consumers of one
    /// policy, and writing the policy at both sites had already let them
    /// drift — the repair refused to label a single-voice meeting while
    /// re-processing happily numbered it, so identical audio was attributed
    /// two different ways depending on which path reached it.
    struct Attribution {
        /// Spans worth attributing, slivers already removed.
        let spans: [SpeakerAlignment.Span]
        /// Display name per cluster label — a person's name where one was
        /// confidently recognised, the number otherwise.
        let names: [String: String]
        let voiceCount: Int

        /// What a segment covering this range should be called.
        ///
        /// Nil when nothing overlaps it and there is more than one voice to
        /// choose from: a "Yeah" during someone's monologue is usually the
        /// listener, not the talker, so nearest-in-time would guess wrong and
        /// the plain label is more honest. With exactly one remote voice there
        /// is nobody else it could be, and leaving the diarizer's misses
        /// unlabelled is what made a 1:1 show a third, anonymous "Speaker"
        /// whose every line was "Okay."
        func speaker(from start: TimeInterval, to end: TimeInterval) -> Speaker? {
            if let id = SpeakerAlignment.dominantSpeakerID(from: start, to: end, in: spans),
               let label = labels[id] {
                return .other(names[label] ?? label)
            }
            return soleVoice
        }

        /// The one remote voice, when there is exactly one.
        var soleVoice: Speaker? {
            guard labels.count == 1, let label = labels.values.first else { return nil }
            return .other(names[label] ?? label)
        }

        /// Cluster id → display label ("Speaker 2"). Internal so a test can
        /// build an attribution without running the diarizer.
        let labels: [String: String]
    }

    /// Resolve diarization into speakers, persisting the voice signatures on
    /// the way so this meeting can be identified later without its audio.
    ///
    /// `minimumVoices` is the one knob the two callers disagree on: a repair
    /// gains nothing by renaming one anonymous voice to "Speaker 1", while a
    /// fresh transcript may as well be numbered consistently.
    @MainActor
    static func attribute(
        diarized: [DiarizedSegment],
        meeting: Meeting,
        minimumVoices: Int = 1
    ) -> Attribution? {
        let spans = diarized.map {
            SpeakerAlignment.Span(speakerID: $0.speakerID, start: $0.startTime, end: $0.endTime)
        }
        let significant = SpeakerAlignment.significantSpeakerIDs(in: spans)
        guard significant.count >= minimumVoices, !significant.isEmpty else { return nil }

        let usable = spans.filter { significant.contains($0.speakerID) }
        let labels = SpeakerAlignment.labels(forSpansOrderedByTime: usable)
        let clusters = clusters(from: diarized, labels: labels, significant: significant)

        if !clusters.isEmpty {
            StorageManager.shared.saveVoiceClusters(
                MeetingVoiceClusters(clusters: clusters.map { .init(label: $0.label, signature: $0.signature) }),
                for: meeting.id
            )
        }

        let resolutions = resolve(
            clusters: clusters,
            attendeeIDs: Set(meeting.attendees.map(\.id)),
            profiles: VoiceProfileStore.load()
        )
        for resolution in resolutions where resolution.identified != nil {
            LogManager.send(
                "Recognised \(resolution.displayName) as \(resolution.label) (\(String(format: "%.2f", resolution.identified?.similarity ?? 0)))",
                category: .transcription,
                meetingID: meeting.id
            )
        }

        return Attribution(
            spans: usable,
            names: Dictionary(uniqueKeysWithValues: resolutions.map { ($0.label, $0.displayName) }),
            voiceCount: significant.count,
            labels: labels
        )
    }

    /// Build signatures for each significant cluster from its turns.
    static func clusters(
        from turns: [DiarizedSegment],
        labels: [String: String],
        significant: Set<String>
    ) -> [Cluster] {
        var grouped: [String: [(embedding: [Float], seconds: Double)]] = [:]
        for turn in turns where significant.contains(turn.speakerID) {
            grouped[turn.speakerID, default: []].append(
                (turn.embedding, max(0, turn.endTime - turn.startTime))
            )
        }
        return grouped.compactMap { clusterID, samples in
            guard let label = labels[clusterID],
                  let signature = VoiceSignature.from(turns: samples) else { return nil }
            return Cluster(clusterID: clusterID, label: label, signature: signature)
        }
        .sorted { $0.label < $1.label }
    }

    /// Name the clusters we're sure about, leaving the rest numbered.
    ///
    /// Two people are never given the same name: a meeting has one Erin, and a
    /// second cluster matching her profile means the clusterer split one voice
    /// or two people sound alike. Either way, asserting both are Erin is
    /// wrong, so the weaker claim stays numbered.
    static func resolve(
        clusters: [Cluster],
        attendeeIDs: Set<UUID>,
        profiles: [VoiceProfileStore.Profile]
    ) -> [Resolution] {
        let scored = clusters.map { cluster in
            (cluster, VoiceProfileStore.bestMatch(
                for: cluster.signature,
                among: attendeeIDs.isEmpty ? nil : attendeeIDs,
                profiles: profiles
            ))
        }

        // Strongest claim on each person wins.
        var claimed: [UUID: Float] = [:]
        for (_, match) in scored {
            guard let match, VoiceProfileStore.isConfident(match) else { continue }
            let id = match.profile.contactID
            claimed[id] = max(claimed[id] ?? 0, match.similarity)
        }

        var used = Set<UUID>()
        return scored.map { cluster, match in
            guard let match, VoiceProfileStore.isConfident(match) else {
                return Resolution(label: cluster.label, identified: nil)
            }
            let id = match.profile.contactID
            let isStrongest = claimed[id] == match.similarity && !used.contains(id)
            if isStrongest { used.insert(id) }
            return Resolution(label: cluster.label, identified: isStrongest ? match : nil)
        }
    }
}
