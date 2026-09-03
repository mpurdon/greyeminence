import XCTest
@testable import Grey_Eminence

/// Deciding which diarized clusters get a name automatically. The bias
/// throughout is toward leaving a number in place: "Speaker 2" tells the
/// reader nothing, but the wrong name tells them something false.
final class SpeakerIdentificationTests: XCTestCase {

    private func sig(_ v: [Float], seconds: Double = 120) -> VoiceSignature {
        VoiceSignature.from(turns: [(v, seconds)])!
    }

    private func profile(_ name: String, _ v: [Float], id: UUID = UUID()) -> VoiceProfileStore.Profile {
        .init(contactID: id, contactName: name, signature: sig(v), meetingCount: 3, updatedAt: .now)
    }

    private func cluster(_ label: String, _ v: [Float]) -> SpeakerIdentification.Cluster {
        .init(clusterID: label, label: label, signature: sig(v))
    }

    // MARK: - Building clusters from turns

    func testClusterSignatureCombinesItsTurns() {
        let turns = [
            DiarizedSegment(speaker: .other("Speaker 1"), startTime: 0, endTime: 60, confidence: 1, speakerID: "a", embedding: [1, 0]),
            DiarizedSegment(speaker: .other("Speaker 1"), startTime: 70, endTime: 130, confidence: 1, speakerID: "a", embedding: [1, 0]),
        ]
        let clusters = SpeakerIdentification.clusters(from: turns, labels: ["a": "Speaker 1"], significant: ["a"])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].signature.seconds, 120, accuracy: 0.001)
    }

    func testSliverClustersAreExcluded() {
        // Same filter the transcript labelling uses; a signature built from a
        // cough would be enrolled as somebody's voice.
        let turns = [
            DiarizedSegment(speaker: .other("Speaker 1"), startTime: 0, endTime: 60, confidence: 1, speakerID: "a", embedding: [1, 0]),
            DiarizedSegment(speaker: .other("Speaker 2"), startTime: 61, endTime: 61.3, confidence: 1, speakerID: "b", embedding: [0, 1]),
        ]
        let clusters = SpeakerIdentification.clusters(
            from: turns,
            labels: ["a": "Speaker 1", "b": "Speaker 2"],
            significant: ["a"]
        )
        XCTAssertEqual(clusters.map(\.label), ["Speaker 1"])
    }

    func testTurnsWithoutEmbeddingsProduceNoCluster() {
        let turns = [
            DiarizedSegment(speaker: .other("Speaker 1"), startTime: 0, endTime: 60, confidence: 1, speakerID: "a", embedding: [])
        ]
        XCTAssertTrue(
            SpeakerIdentification.clusters(from: turns, labels: ["a": "Speaker 1"], significant: ["a"]).isEmpty
        )
    }

    // MARK: - Attributing segments

    private func attribution(labels: [String: String], names: [String: String]? = nil) -> SpeakerIdentification.Attribution {
        let spans = labels.keys.sorted().enumerated().map { index, id in
            SpeakerAlignment.Span(speakerID: id, start: Double(index) * 100, end: Double(index) * 100 + 60)
        }
        return .init(
            spans: spans,
            names: names ?? Dictionary(uniqueKeysWithValues: labels.values.map { ($0, $0) }),
            voiceCount: labels.count,
            labels: labels
        )
    }

    func testUnattributedSpeechGoesToTheOnlyVoice() {
        // The diarizer skips one-word interjections; in a 1:1 they can only
        // be the one remote person, and labelling them "Speaker" showed a
        // third participant who said nothing but "Okay."
        let single = attribution(labels: ["a": "Speaker 1"])
        XCTAssertEqual(single.speaker(from: 5, to: 8), .other("Speaker 1"))
        XCTAssertEqual(single.speaker(from: 500, to: 501), .other("Speaker 1"), "no overlap, but nobody else it could be")
    }

    func testSoleVoiceCarriesItsRecognisedName() {
        let single = attribution(labels: ["a": "Speaker 1"], names: ["Speaker 1": "Liran"])
        XCTAssertEqual(single.speaker(from: 500, to: 501), .other("Liran"))
    }

    func testUnattributedSpeechStaysUnlabelledWithSeveralVoices() {
        // A "Yeah" during someone's monologue is usually the listener; with
        // two candidates the honest answer is not to guess.
        let pair = attribution(labels: ["a": "Speaker 1", "b": "Speaker 2"])
        XCTAssertEqual(pair.speaker(from: 5, to: 8), .other("Speaker 1"))
        XCTAssertEqual(pair.speaker(from: 105, to: 108), .other("Speaker 2"))
        XCTAssertNil(pair.speaker(from: 500, to: 501))
        XCTAssertNil(pair.soleVoice)
    }

    // MARK: - Resolving to people

    func testConfidentMatchIsApplied() {
        let erin = profile("Erin", [1, 0, 0])
        let resolved = SpeakerIdentification.resolve(
            clusters: [cluster("Speaker 1", [0.99, 0.1, 0])],
            attendeeIDs: [erin.contactID],
            profiles: [erin]
        )
        XCTAssertEqual(resolved[0].displayName, "Erin")
    }

    func testWeakMatchLeavesTheNumberInPlace() {
        let erin = profile("Erin", [1, 0, 0])
        let resolved = SpeakerIdentification.resolve(
            clusters: [cluster("Speaker 1", [1, 2, 0])],
            attendeeIDs: [erin.contactID],
            profiles: [erin]
        )
        XCTAssertNil(resolved[0].identified)
        XCTAssertEqual(resolved[0].displayName, "Speaker 1")
    }

    func testOnePersonIsNeverAssignedToTwoSpeakers() {
        // A meeting has one Erin. Two clusters matching her means the
        // clusterer split her voice, or two people sound alike — either way
        // asserting both are Erin is wrong, so only the stronger claim wins.
        let erin = profile("Erin", [1, 0, 0])
        let resolved = SpeakerIdentification.resolve(
            clusters: [cluster("Speaker 1", [1, 0, 0]), cluster("Speaker 2", [0.97, 0.15, 0])],
            attendeeIDs: [erin.contactID],
            profiles: [erin]
        )
        XCTAssertEqual(resolved.filter { $0.identified != nil }.count, 1)
        let named = resolved.first { $0.identified != nil }
        XCTAssertEqual(named?.label, "Speaker 1", "the closer cluster should keep the name")
        XCTAssertEqual(resolved.first { $0.identified == nil }?.displayName, "Speaker 2")
    }

    func testNonAttendeesAreNeverNamed() {
        let erin = profile("Erin", [1, 0, 0])
        let resolved = SpeakerIdentification.resolve(
            clusters: [cluster("Speaker 1", [1, 0, 0])],
            attendeeIDs: [UUID()],
            profiles: [erin]
        )
        XCTAssertNil(resolved[0].identified)
        XCTAssertEqual(resolved[0].displayName, "Speaker 1")
    }

    func testNoProfilesMeansEverythingStaysNumbered() {
        let resolved = SpeakerIdentification.resolve(
            clusters: [cluster("Speaker 1", [1, 0, 0])],
            attendeeIDs: [UUID()],
            profiles: []
        )
        XCTAssertEqual(resolved.map(\.displayName), ["Speaker 1"])
    }

    // MARK: - What counts as unidentified

    func testNumberedAndCollapsedLabelsAreBothUnidentified() {
        XCTAssertTrue(SpeakerIdentityService.isUnidentified("Speaker"))
        XCTAssertTrue(SpeakerIdentityService.isUnidentified("Speaker 1"))
        XCTAssertTrue(SpeakerIdentityService.isUnidentified("Speaker 12"))
    }

    func testRealNamesAreNotUnidentified() {
        XCTAssertFalse(SpeakerIdentityService.isUnidentified("Erin O'Brien"))
        XCTAssertFalse(SpeakerIdentityService.isUnidentified("Me"))
        // A person whose name happens to start the same way must not be
        // treated as an anonymous cluster.
        XCTAssertFalse(SpeakerIdentityService.isUnidentified("Speakerman"))
    }
}

/// The "unidentified voice" vocabulary, which lived as a string literal in six
/// places — produced in two, matched in four, and already inconsistent about
/// case. It belongs to `Speaker`.
@MainActor
final class SpeakerVocabularyTests: XCTestCase {

    func testNumberedSpeakersAreUnidentified() {
        XCTAssertTrue(Speaker.numbered(1).isUnidentified)
        XCTAssertTrue(Speaker.numbered(12).isUnidentified)
        XCTAssertTrue(Speaker.unidentified.isUnidentified)
    }

    func testPeopleAreNot() {
        XCTAssertFalse(Speaker.other("Erin O'Brien").isUnidentified)
        XCTAssertFalse(Speaker.me.isUnidentified)
    }

    func testANameThatMerelyStartsTheSameWayIsNot() {
        // A prefix check treats these as anonymous clusters and would let a
        // repair overwrite a real person's name with a number.
        XCTAssertFalse(Speaker.other("Speakerman").isUnidentified)
        XCTAssertFalse(Speaker.other("Speaker Smith").isUnidentified)
        XCTAssertFalse(Speaker.other("Speakers").isUnidentified)
    }

    func testNumberingMatchesWhatTheRepairLooksFor() {
        // Producer and consumer agreeing is the whole point of moving this
        // onto the type.
        XCTAssertEqual(Speaker.unidentified.displayName, SpeakerRepairService.collapsedLabel)
        XCTAssertTrue(SpeakerIdentityService.isUnidentified(Speaker.numbered(3).displayName))
        XCTAssertTrue(SpeakerIdentityService.isUnidentified(Speaker.unidentified.displayName))
    }
}
