import XCTest
@testable import Grey_Eminence

@MainActor
final class DiagramTests: XCTestCase {

    // MARK: - Detection

    func testSignalsParseFilterAndCap() {
        XCTAssertNil(DiagramSignal.parseList(nil), "absent: keep the earlier judgement")
        XCTAssertEqual(DiagramSignal.parseList([]), [], "present and empty: nothing to draw")

        let signals = DiagramSignal.parseList([
            ["kind": "flow", "title": "Lead intake", "likelihood": 0.9],
            ["kind": "Gantt", "title": "Q4 deliverables", "likelihood": "0.8"],
            ["kind": "flow", "title": " lead INTAKE ", "likelihood": 0.7],   // same diagram
            ["kind": "flow", "title": "Passing mention", "likelihood": 0.2],  // below threshold
            ["kind": "flow", "title": "", "likelihood": 0.9],                 // no title
            ["kind": "timeline", "title": "Pilot", "likelihood": 0.6],
            ["kind": "flow", "title": "One too many", "likelihood": 0.9],
        ])
        XCTAssertEqual(Set(signals?.map(\.title) ?? []), ["Lead intake", "One too many", "Q4 deliverables"],
                       "the three most likely, duplicates and untitled dropped")
        XCTAssertEqual(signals?.first { $0.title == "Q4 deliverables" }?.kind, .timeline, "gantt reads as a timeline")

        // Kept whatever the likelihood; the threshold applies when listing.
        let low = DiagramSignal.parseList([["kind": "flow", "title": "Passing mention", "likelihood": 0.2]])
        XCTAssertEqual(low?.count, 1)
        XCTAssertEqual(low?.first?.isListed, false)
        XCTAssertEqual(DiagramKind(lenient: "Gantt chart"), .timeline)
        XCTAssertEqual(DiagramKind(lenient: "flowchart"), .flow)
    }

    func testIDsBecomeStringsOnlyWhereIDsGo() {
        let fixed = DiagramService.stringifyingIDs([
            "nodes": [["id": 1, "label": "a"]],
            "edges": [["from": 1, "to": 2]],
            "items": [["id": 3, "depends_on": [1, "d2"]]],
            "summary": ["id": 7],
        ])
        XCTAssertEqual((fixed["nodes"] as? [[String: Any]])?.first?["id"] as? String, "1")
        XCTAssertEqual((fixed["edges"] as? [[String: Any]])?.first?["to"] as? String, "2")
        XCTAssertEqual((fixed["items"] as? [[String: Any]])?.first?["depends_on"] as? [String], ["1", "d2"])
        XCTAssertEqual((fixed["summary"] as? [String: Any])?["id"] as? Int, 7, "an unrelated object is left alone")
    }

    func testBackfillParseMapsIdentifiers() {
        let response = """
        {"meetings":[
          {"id":"M1","diagrams":[{"kind":"timeline","title":"Launch plan","likelihood":0.8}]},
          {"id":"M2","diagrams":[]},
          {"id":"M9","diagrams":[]}
        ]}
        """
        let parsed = DiagramBackfill.parse(response: response, count: 3)
        XCTAssertEqual(parsed[0]?.map(\.title), ["Launch plan"])
        XCTAssertEqual(parsed[1], [], "assessed, nothing found")
        XCTAssertNil(parsed[2], "skipped by the model: stays unassessed")
    }

    // MARK: - Parsing drawings

    func testFlowParsesNumericIDsAndNulls() throws {
        let flow = try XCTUnwrap(DiagramService.parseFlow(response: """
        ```json
        {"title":"Lead intake","summary":null,"nodes":[
          {"id":1,"label":"Lead received","kind":"start","actor":null,"citations":["0:50"]},
          {"id":2,"label":"Retention call ok?","kind":"Decision","actor":"Lambda"},
          {"id":"3","label":"Store certificate","kind":"step"}
        ],"edges":[{"from":1,"to":2},{"from":2,"to":"3","label":"yes"},{"from":2,"to":99}],
        "open_questions":["Backoff?"]}
        ```
        """))
        XCTAssertEqual(flow.nodes.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(flow.nodes[1].kind, .decision)
        XCTAssertEqual(flow.validEdges.count, 2, "an edge to a node that doesn't exist is dropped")
        XCTAssertEqual(flow.openQuestions, ["Backoff?"])
    }

    func testTimelineParsesDatesAndSplitsUndated() throws {
        let timeline = try XCTUnwrap(DiagramService.parseTimeline(response: """
        {"title":"Q4","items":[
          {"id":"d1","name":"Schema","owner":"Liran","due":"2026-10-02","date_text":"Friday","confidence":"estimated","citations":["3:10"]},
          {"id":"d2","name":"Pilot","start":"2026-10-05","due":"2026-10-20","is_milestone":false,"depends_on":["d1"]},
          {"id":"d3","name":"Launch","due":"2026-11-01","is_milestone":true,"confidence":"exact"},
          {"id":"d4","name":"Docs","due":null,"date_text":"after the pilot"}
        ],"notes":["Depends on legal"]}
        """))
        XCTAssertEqual(timeline.dated.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(timeline.undated.map(\.name), ["Docs"])
        XCTAssertTrue(timeline.items[0].isEstimated)
        XCTAssertEqual(timeline.items[1].dependsOn, ["d1"])
        XCTAssertEqual(timeline.items[0].dueDate.map(TimelineDiagram.string(from:)), "2026-10-02")
        XCTAssertNil(DiagramService.parseTimeline(response: "Sorry."))
    }

    func testPromptsCarryTheMeetingDateAndLeaveNoPlaceholders() {
        let date = TimelineDiagram.date(from: "2026-09-22")!
        for kind in DiagramKind.allCases {
            let input = DiagramService.Input(meetingTitle: "OLP sync", date: date, participants: ["Liran"], screenContext: nil,
                                             transcript: "[0:01] Liran: schema by Friday", kind: kind, title: "Q4 plan")
            let prompt = DiagramService.userPrompt(for: input)
            XCTAssertTrue(prompt.contains("\"Q4 plan\""), kind.rawValue)
            XCTAssertTrue(prompt.contains("2026-09-22"), kind.rawValue)
            XCTAssertFalse(prompt.contains("{{"), kind.rawValue)
        }
        let timeline = DiagramService.userPrompt(for: .init(meetingTitle: "x", date: date, participants: [], screenContext: nil,
                                                            transcript: "t", kind: .timeline, title: "t"))
        XCTAssertTrue(timeline.contains("Tuesday"), "relative dates need the weekday")
    }

    // MARK: - Layout

    private func node(_ id: String, _ kind: FlowDiagram.NodeKind = .step) -> FlowDiagram.Node {
        .init(id: id, label: id, kind: kind)
    }

    private func flow(_ nodes: [FlowDiagram.Node], _ edges: [(String, String)]) -> FlowDiagram {
        FlowDiagram(title: "t", nodes: nodes, edges: edges.map { .init(from: $0.0, to: $0.1) })
    }

    func testAChainGoesStraightDown() {
        let layout = FlowDiagramLayout(flow([node("a", .start), node("b"), node("c", .end)], [("a", "b"), ("b", "c")]))
        XCTAssertEqual(layout.ranks, ["a": 0, "b": 1, "c": 2])
        XCTAssertEqual(layout.frames["a"]?.midX, layout.frames["c"]?.midX)
        XCTAssertLessThan(layout.frames["a"]!.maxY, layout.frames["b"]!.minY)
    }

    func testABranchSpreadsSidewaysAndALoopGoesUpTheSide() {
        let layout = FlowDiagramLayout(flow(
            [node("start", .start), node("call"), node("ok?", .decision), node("store"), node("retry"), node("done", .end)],
            [("start", "call"), ("call", "ok?"), ("ok?", "store"), ("ok?", "retry"), ("retry", "call"), ("store", "done")]
        ))
        XCTAssertEqual(layout.ranks["store"], layout.ranks["retry"], "both branches on one row")
        XCTAssertNotEqual(layout.frames["store"]?.midX, layout.frames["retry"]?.midX)
        let loop = layout.routes.first { $0.edge.from == "retry" && $0.edge.to == "call" }
        XCTAssertNotNil(loop?.laneX, "the retry is drawn back up the side")
        XCTAssertEqual(layout.routes.filter { $0.laneX != nil }.count, 1)

        // Nothing overlaps.
        let frames = Array(layout.frames.values)
        for i in frames.indices { for j in frames.indices where i < j {
            XCTAssertFalse(frames[i].intersects(frames[j]))
        } }
        XCTAssertTrue(frames.allSatisfy { layout.size.width >= $0.maxX && layout.size.height >= $0.maxY })
    }

    func testAnArrowThatSkipsLayersGoesAroundTheNodesInBetween() {
        // The lead-routing shape: "no rule" jumps from the top decision past
        // the zip check straight to Bypass.
        let layout = FlowDiagramLayout(flow(
            [node("lead", .start), node("rule?", .decision), node("zip?", .decision), node("check zip"), node("state?", .decision),
             node("bypass"), node("check state"), node("match?", .decision), node("route", .end), node("exclude", .end)],
            [("lead", "rule?"), ("rule?", "zip?"), ("rule?", "bypass"), ("zip?", "check zip"), ("zip?", "state?"),
             ("state?", "bypass"), ("state?", "check state"), ("check zip", "match?"), ("check state", "match?"),
             ("bypass", "route"), ("match?", "route"), ("match?", "exclude")]
        ))
        let skipping = layout.routes.filter { $0.points.count > 2 }
        XCTAssertFalse(skipping.isEmpty)
        for route in layout.routes {
            for (start, end) in zip(route.points, route.points.dropFirst()) where start.x == end.x && start.y < end.y {
                // A leg straight down through a layer touches no node there.
                let leg = CGRect(x: start.x - 0.5, y: start.y + 1, width: 1, height: end.y - start.y - 2)
                for (id, frame) in layout.frames where id != route.edge.from && id != route.edge.to {
                    XCTAssertFalse(frame.intersects(leg), "\(route.edge.from)→\(route.edge.to) crosses \(id)")
                }
            }
        }
        // A straight chain stays straight.
        XCTAssertEqual(layout.frames["lead"]?.midX, layout.frames["rule?"]?.midX)
    }

    func testPlacementKeepsOrderAndSpacing() {
        let placed = FlowDiagramLayout.placeInOrder(desired: [100, 90, 300], separations: [50, 50])
        XCTAssertEqual(placed[1] - placed[0], 50, accuracy: 0.001)
        XCTAssertEqual((placed[0] + placed[1]) / 2, 95 + 0, accuracy: 0.001)
        XCTAssertEqual(placed[2], 300, accuracy: 0.001)
    }

    func testLayoutSurvivesDuplicatesStraysAndNoStart() {
        let layout = FlowDiagramLayout(flow([node("a"), node("a"), node("b"), node("lonely")], [("a", "b"), ("b", "ghost")]))
        XCTAssertEqual(Set(layout.frames.keys), ["a", "b", "lonely"])
        XCTAssertEqual(layout.routes.count, 1)
    }

    func testTidyingStopsAtEndsAndDemotesOneWayDecisions() {
        // The shape of a real miss: two outcomes, then the meeting's
        // discussion hung off both ends.
        let tidy = flow(
            [node("lead", .start), node("match?", .decision), node("link", .end), node("create", .end),
             node("weaknesses"), node("redesign"), node("owner?", .decision), node("ship", .end)],
            [("lead", "match?"), ("match?", "link"), ("match?", "create"), ("link", "weaknesses"), ("create", "weaknesses"),
             ("weaknesses", "redesign"), ("redesign", "owner?"), ("owner?", "ship")]
        ).tidied()
        XCTAssertEqual(tidy.nodes.map(\.id), ["lead", "match?", "link", "create"])
        XCTAssertEqual(tidy.edges.count, 3)
        XCTAssertEqual(tidy.nodes[1].kind, .decision, "two ways out stays a decision")

        let oneWay = flow([node("a", .start), node("ok?", .decision), node("b", .end)], [("a", "ok?"), ("ok?", "b")]).tidied()
        XCTAssertEqual(oneWay.nodes[1].kind, .step)

        // With no start to walk from, nothing is dropped.
        let noStart = flow([node("a"), node("b"), node("lonely")], [("a", "b")]).tidied()
        XCTAssertEqual(noStart.nodes.count, 3)
    }

    func testDiagramIDIsStableAndShapedLikeAMeetingID() throws {
        let meeting = try XCTUnwrap(UUID(uuidString: "25B3479B-D53D-45E1-944B-5ADB60E4C62B"))
        let id = DiagramTopic.diagramID(meetingID: meeting, signalID: "flow|lead routing")
        XCTAssertEqual(id, DiagramTopic.diagramID(meetingID: meeting, signalID: "flow|lead routing"))
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertNotEqual(id, DiagramTopic.diagramID(meetingID: meeting, signalID: "timeline|lead routing"))
    }

    func testIgnoredItemsLeaveTheTimelineButAreKept() {
        var timeline = TimelineDiagram(title: "t", items: [
            .init(id: "d1", name: "Schema", due: "2026-10-09"),
            .init(id: "d2", name: "Pilot"),
            .init(id: "d3", name: "Docs", isIgnored: true),
        ])
        XCTAssertEqual(timeline.undated.map(\.id), ["d2"])
        XCTAssertEqual(timeline.ignored.map(\.id), ["d3"])
        XCTAssertEqual(TimelineRows(timeline).dated.map(\.item.id), ["d1"])
        timeline.items[1].isIgnored = true
        XCTAssertTrue(timeline.undated.isEmpty)
        XCTAssertFalse(DiagramMermaid.timeline(timeline).contains("Pilot"))
    }

    // MARK: - Export and rows

    func testMermaid() throws {
        let flow = FlowDiagram(
            title: "t",
            nodes: [.init(id: "n-1", label: "Lead \"received\"", kind: .start), .init(id: "2", label: "Ok?", kind: .decision, actor: "Lambda")],
            edges: [.init(from: "n-1", to: "2", label: "then")]
        )
        let text = DiagramMermaid.flow(flow)
        XCTAssertTrue(text.hasPrefix("flowchart TD"))
        XCTAssertTrue(text.contains("n_1([\"Lead #quot;received#quot;\"])"))
        XCTAssertTrue(text.contains("n2{\"Ok?<br/><i>Lambda</i>\"}"))
        XCTAssertTrue(text.contains("n_1 -->|then| n2"))

        let timeline = TimelineDiagram(title: "Q4", items: [
            .init(id: "d1", name: "Pilot", start: "2026-10-05", due: "2026-10-20"),
            .init(id: "d2", name: "Launch", due: "2026-11-01", isMilestone: true),
            .init(id: "d3", name: "Docs", dateText: "after the pilot"),
        ])
        let gantt = DiagramMermaid.timeline(timeline)
        XCTAssertTrue(gantt.contains("Pilot :d1, 2026-10-05, 2026-10-20"))
        XCTAssertTrue(gantt.contains("Launch :milestone, d2, 2026-11-01, 0d"))
        XCTAssertTrue(gantt.contains("%% No date: Docs — after the pilot"))
    }

    func testTimelineRowsAreUniqueAndOrderedByDate() {
        let rows = TimelineRows(TimelineDiagram(title: "t", items: [
            .init(id: "b", name: "Review", due: "2026-10-20"),
            .init(id: "a", name: "Review", due: "2026-10-01"),
        ]))
        XCTAssertEqual(rows.dated.map(\.item.id), ["a", "b"])
        XCTAssertEqual(rows.dated.map(\.label), ["Review", "Review (2)"])
        let meeting = TimelineDiagram.date(from: "2026-09-22")!
        XCTAssertTrue(rows.domain(including: meeting, today: nil).contains(meeting))
    }

    func testDiagramPromptsUseEveryPlaceholder() {
        for key in [PromptKey.diagramFlow, .diagramTimeline, .diagramClassify] {
            let text = AIPromptTemplates.defaultText(for: key)
            for placeholder in key.placeholders where !(key == .diagramFlow && placeholder == "meetingWeekday") {
                XCTAssertTrue(text.contains("{{\(placeholder)}}"), "\(key.rawValue) never uses {{\(placeholder)}}")
            }
        }
        XCTAssertTrue(AIPromptTemplates.defaultText(for: .meetingSystem).contains(AIPromptTemplates.diagramDetectionRules))
    }

    func testTranscriptFragmentsJoinIntoPassagesPerSpeaker() {
        let lines = [("Jakub", "The update is, we already"), ("Jakub", "enabled the"), ("Jakub", "new tracing collector,"),
                     ("Liran", "  Nice. "), ("Jakub", "and tested it")]
            .map { RefinementPassage.Line(id: UUID(), startTime: 0, speaker: $0.0, text: $0.1) }
        XCTAssertEqual(TranscriptExcerpt.merge(lines), [
            .init(speaker: "Jakub", text: "The update is, we already enabled the new tracing collector,"),
            .init(speaker: "Liran", text: "Nice."),
            .init(speaker: "Jakub", text: "and tested it"),
        ])
    }
}
