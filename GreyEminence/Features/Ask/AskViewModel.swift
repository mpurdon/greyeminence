import Foundation
import SwiftData

@Observable
@MainActor
final class AskViewModel {
    enum Phase: Equatable {
        case idle
        /// Rewriting a follow-up into a standalone search query.
        case condensing
        case searching
        case answering
    }

    var conversations: [AskConversation] = []
    var selectedConversationID: UUID?
    var draft: String = ""
    var phase: Phase = .idle
    /// Citation tapped in an answer — the sources panel scrolls to it and
    /// highlights it.
    var selectedSourceNumber: Int?
    /// When set, the sources panel narrows to the snippets that grounded one
    /// turn instead of the whole pool.
    var focusedTurnID: UUID?

    private var activeTask: Task<Void, Never>?
    /// Turn the in-flight task belongs to. Its completion block checks this
    /// before touching shared state: cancelling and immediately asking again
    /// leaves the old task still unwinding, and without the check its tail
    /// would reset the phase and drop the *new* task's handle.
    private var activeTurnID: UUID?

    /// How many prior answers' citations get carried into the next prompt.
    /// Two covers the common "and what about…" chain without dragging the
    /// whole thread's evidence along forever.
    private let carryForwardTurns = 2

    var isBusy: Bool { phase != .idle }

    var currentConversation: AskConversation? {
        guard let id = selectedConversationID else { return nil }
        return conversations.first { $0.id == id }
    }

    var sortedConversations: [AskConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    init() {
        conversations = AskConversationStore.load()
        selectedConversationID = sortedConversations.first?.id
    }

    // MARK: - Conversation management

    func startNewConversation() {
        activeTask?.cancel()
        activeTurnID = nil
        phase = .idle
        draft = ""
        selectedSourceNumber = nil
        focusedTurnID = nil
        // An empty thread is a scratch pad, not history: reuse the one that's
        // already open rather than stacking up untouched "New conversation"
        // rows every time the button is pressed.
        if let existing = conversations.first(where: { $0.turns.isEmpty }) {
            selectedConversationID = existing.id
            return
        }
        selectedConversationID = nil
    }

    func select(_ conversation: AskConversation) {
        guard conversation.id != selectedConversationID else { return }
        activeTask?.cancel()
        activeTurnID = nil
        phase = .idle
        selectedConversationID = conversation.id
        selectedSourceNumber = nil
        focusedTurnID = nil
    }

    func delete(_ conversation: AskConversation) {
        conversations.removeAll { $0.id == conversation.id }
        if selectedConversationID == conversation.id {
            activeTask?.cancel()
            activeTurnID = nil
            phase = .idle
            selectedConversationID = sortedConversations.first?.id
            selectedSourceNumber = nil
            focusedTurnID = nil
        }
        persist()
    }

    func deleteAll() {
        activeTask?.cancel()
        activeTurnID = nil
        phase = .idle
        conversations = []
        selectedConversationID = nil
        selectedSourceNumber = nil
        focusedTurnID = nil
        persist()
    }

    func rename(_ conversation: AskConversation, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].title = trimmed
        persist()
    }

    func setDateFilter(_ filter: AskDateFilter) {
        guard let index = selectedIndex else { return }
        conversations[index].dateFilterRaw = filter.rawValue
        persist()
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeTurnID = nil
        phase = .idle
        // A turn that was mid-flight has no answer and never will — mark it so
        // the bubble reads as cancelled rather than hanging on a spinner.
        guard let index = selectedIndex,
              let last = conversations[index].turns.indices.last,
              conversations[index].turns[last].answer == nil,
              conversations[index].turns[last].errorMessage == nil else { return }
        conversations[index].turns[last].errorMessage = "Cancelled."
        persist()
    }

    /// Drop the last exchange and ask it again — for a failed turn, or an
    /// answer that missed. The snippets it pulled in stay in the pool.
    func retryLastTurn(mainContext: ModelContext, snippetCount: Int, contextWindow: Int) {
        guard !isBusy, let index = selectedIndex else { return }
        guard let last = conversations[index].turns.popLast() else { return }
        persist()
        send(
            question: last.question,
            mainContext: mainContext,
            snippetCount: snippetCount,
            contextWindow: contextWindow
        )
    }

    // MARK: - Asking

    func submitDraft(mainContext: ModelContext, snippetCount: Int, contextWindow: Int, defaultFilter: AskDateFilter) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        draft = ""
        ensureConversation(defaultFilter: defaultFilter)
        send(
            question: trimmed,
            mainContext: mainContext,
            snippetCount: snippetCount,
            contextWindow: contextWindow
        )
    }

    private func send(question: String, mainContext: ModelContext, snippetCount: Int, contextWindow: Int) {
        guard let index = selectedIndex else { return }

        let turn = AskTurn(question: question)
        conversations[index].turns.append(turn)
        conversations[index].updatedAt = .now
        if conversations[index].turns.count == 1 {
            conversations[index].title = AskConversation.title(fromFirstQuestion: question)
        }
        focusedTurnID = nil
        selectedSourceNumber = nil
        persist()

        let conversationID = conversations[index].id
        let turnID = turn.id
        activeTurnID = turnID
        activeTask = Task { [weak self] in
            await self?.run(
                turnID: turnID,
                conversationID: conversationID,
                question: question,
                mainContext: mainContext,
                snippetCount: snippetCount,
                contextWindow: contextWindow
            )
            guard let self, self.activeTurnID == turnID else { return }
            self.phase = .idle
            self.activeTask = nil
            self.activeTurnID = nil
        }
    }

    private func run(
        turnID: UUID,
        conversationID: UUID,
        question: String,
        mainContext: ModelContext,
        snippetCount: Int,
        contextWindow: Int
    ) async {
        guard let store = EmbeddingStore.shared else {
            failTurn(turnID, in: conversationID, message: "The embedding store isn't available, so there's nothing to search.")
            return
        }
        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider") ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let embedding = provider.makeService()
        guard embedding.isAvailable else {
            failTurn(turnID, in: conversationID, message: "The \(provider.shortLabel) embedding provider isn't implemented yet. Switch to On-device in Settings → Ask.")
            return
        }
        guard let client = try? await AIClientFactory.makeClient() else {
            failTurn(turnID, in: conversationID, message: "No AI client is configured, so snippets can't be turned into an answer. Check Settings → AI.")
            return
        }
        guard !Task.isCancelled else { return }

        // 1. Condense a follow-up into a standalone query.
        let priorTurns = conversation(conversationID)?.turns.dropLast().filter { $0.answer != nil } ?? []
        var searchQuery = question
        if !priorTurns.isEmpty {
            phase = .condensing
            searchQuery = await condense(question: question, history: Array(priorTurns), client: client)
            guard !Task.isCancelled else { return }
            updateTurn(turnID, in: conversationID) { $0.searchQuery = searchQuery }
        }

        // 2. Turn any person named in the question into a filter over the
        //    meetings they attended, and drop their name from the query text.
        let people = resolvePeople(in: searchQuery, mainContext: mainContext)
        if let people {
            updateTurn(turnID, in: conversationID) {
                $0.personFilterNames = people.names
                $0.personFilterMeetingCount = people.meetingCount
            }
        }

        // 3. Retrieve.
        phase = .searching
        let search = SemanticSearchService(store: store, service: embedding)
        // Raw transcript snippets plus screen-share observations and recaps.
        // Derived artifacts (questions, tasks, summaries) stay excluded — short,
        // generic AI-generated text crowded out the actual conversation. Screen
        // observations are different: they're the ONLY record of what was shown.
        let outcome = await search.searchReporting(
            people?.strippedQuery ?? searchQuery,
            topK: 40,
            dateRange: conversation(conversationID)?.dateFilter.range(),
            kinds: [.transcriptSegment, .screenObservation, .sessionNarrative],
            personScope: people?.scope
        )
        guard !Task.isCancelled else { return }
        let found = outcome.results

        // A credential failure must read as one. Before this, an expired
        // AWS session surfaced as "Nothing matched within last 7 days".
        var embeddingFailure: String?
        if case .keywordOnly(let reason)? = outcome.degradation {
            embeddingFailure = reason
            updateTurn(turnID, in: conversationID) {
                $0.retrievalNote = "Keyword matches only — the question couldn't be embedded"
                    + (reason.map { " (\($0))" } ?? "")
            }
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let retrieved = conversations[conversationIndex].absorb(found, turnID: turnID)
        let carried = conversations[conversationIndex].recentlyCitedNumbers(lastTurns: carryForwardTurns)
        updateTurn(turnID, in: conversationID) { $0.retrievedNumbers = retrieved }

        // New hits lead; snippets carried from earlier answers follow, so a
        // follow-up still sees the evidence it's asking about.
        //
        // A person-scoped pool is both small and precise, so widening what
        // reaches the model costs little and matters a lot: the model bridges
        // "couldn't process due to costs" to "there's no way we can turn this
        // on" far better than word-averaged on-device embeddings ever will.
        // Getting the snippet in front of it is most of the battle.
        let promptedCount = people == nil ? snippetCount : max(snippetCount, 25)
        var prompted = Array(retrieved.prefix(promptedCount))
        for number in carried where !prompted.contains(number) {
            prompted.append(number)
        }

        guard !prompted.isEmpty else {
            let filter = conversations[conversationIndex].dateFilter
            let message: String
            if let embeddingFailure {
                message = "The question couldn't be embedded — \(embeddingFailure). "
                    + "Keyword search found nothing either. If this is an expired AWS session, refresh it and try again."
            } else if filter == .anyTime {
                message = "Nothing in the index matched that. If meetings are missing, run \"Reindex all meetings\" in Settings → Ask."
            } else {
                message = "Nothing matched within \(filter.label.lowercased()). Try widening the date range."
            }
            failTurn(turnID, in: conversationID, message: message)
            return
        }

        // 4. Answer.
        let sources = prompted.compactMap { conversations[conversationIndex].source(number: $0) }
        let leadIns = leadIns(for: sources, window: contextWindow, mainContext: mainContext)
        let block = AskPromptBuilder.sourcesBlock(sources, leadIns: leadIns)
        let history = conversations[conversationIndex].turns.dropLast()
        let messages = AskPromptBuilder.messages(
            history: Array(history),
            question: question,
            sourcesBlock: block
        )
        updateTurn(turnID, in: conversationID) { $0.promptedNumbers = prompted }

        phase = .answering
        do {
            let answer = try await AIUsageContext.attribute(.ask) {
                try await client.sendConversation(
                    system: AskPromptBuilder.system,
                    messages: messages,
                    maxTokens: 4096
                )
            }
            guard !Task.isCancelled else { return }
            updateTurn(turnID, in: conversationID) {
                $0.answer = answer
                $0.citedNumbers = AskCitations.cited(in: answer)
            }
        } catch is CancellationError {
            return
        } catch {
            failTurn(turnID, in: conversationID, message: error.localizedDescription)
        }
    }

    private func condense(question: String, history: [AskTurn], client: any AIClient) async -> String {
        do {
            let raw = try await AIUsageContext.attribute(.ask) {
                try await client.sendMessage(
                    system: "You rewrite conversational follow-ups into standalone search queries. Output only the query.",
                    userContent: AskPromptBuilder.condensePrompt(history: history, question: question),
                    maxTokens: 200
                )
            }
            return AskPromptBuilder.sanitizeCondensed(raw, fallback: question)
        } catch {
            // A failed rewrite is not a failed turn — searching the raw
            // question is worse, not broken.
            LogManager.send("Ask: query rewrite failed, searching verbatim: \(error.localizedDescription)", category: .ai, level: .warning)
            return question
        }
    }

    /// A person named in the question, resolved against the roster.
    struct PersonScope {
        let names: [String]
        let scope: SemanticSearchService.PersonScope
        let strippedQuery: String

        var meetingCount: Int { scope.meetingIDs.count }
    }

    /// Resolve any contact named in `query`, and build the scope that narrows
    /// the search to material connected to them.
    ///
    /// Returns nil — meaning "search the question exactly as asked" — when
    /// nobody resolves. Anyone who does resolve contributes both their
    /// meetings and their name, because either one can carry the answer.
    private func resolvePeople(in query: String, mainContext: ModelContext) -> PersonScope? {
        let contacts = (try? mainContext.fetch(FetchDescriptor<Contact>())) ?? []
        guard !contacts.isEmpty else { return nil }

        let roster = contacts.map { contact in
            AskPersonFilter.Candidate(
                canonicalName: contact.name,
                aliases: ([contact.nickname].compactMap { $0 } + contact.speakerAliases)
                    .filter { !$0.isEmpty }
            )
        }
        guard let detection = AskPersonFilter.detect(in: query, roster: roster) else { return nil }

        let matched = contacts.filter { detection.names.contains($0.name) }
        let meetingIDs = Set(matched.flatMap { $0.meetings.map(\.id) })

        // Names to look for in the text. The full name always; the parts only
        // when they're distinctive enough to survive word-boundary matching
        // without swamping the candidate set — "Huh" is a real surname here
        // and also the most common noise token in a transcript.
        var mentionNames = Set<String>()
        for contact in matched {
            mentionNames.insert(contact.name.lowercased())
            for alias in contact.speakerAliases + [contact.nickname].compactMap({ $0 }) where alias.count >= 4 {
                mentionNames.insert(alias.lowercased())
            }
            for part in AskPersonFilter.tokens(contact.name) where part.count >= 4 {
                mentionNames.insert(part)
            }
        }

        guard !meetingIDs.isEmpty || !mentionNames.isEmpty else {
            LogManager.send(
                "Ask: \(detection.names.joined(separator: ", ")) named but nothing to scope to — searching without a person filter",
                category: .general
            )
            return nil
        }

        // A stripped query with nothing left ("what did Stephen say?") has no
        // concept to search for. Keep the scope, but let the original wording
        // drive ranking within it rather than embedding an empty string.
        let stripped = detection.strippedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        LogManager.send(
            "Ask: scoping to \(detection.names.joined(separator: ", ")) — \(meetingIDs.count) meeting(s) attended plus mentions of \(mentionNames.sorted().joined(separator: "/")); searching \"\(stripped.isEmpty ? query : stripped)\"",
            category: .general
        )
        return PersonScope(
            names: detection.names,
            scope: SemanticSearchService.PersonScope(
                meetingIDs: meetingIDs,
                mentionNames: Array(mentionNames)
            ),
            strippedQuery: stripped.isEmpty ? query : stripped
        )
    }

    /// A few segments of run-up for transcript hits, so a snippet that starts
    /// mid-thought reads in context. Screen observations are self-contained
    /// and get none.
    private func leadIns(for sources: [AskSource], window: Int, mainContext: ModelContext) -> [String: String] {
        guard window > 0 else { return [:] }
        var result: [String: String] = [:]
        for source in sources where source.result.sourceKind == .transcriptSegment {
            let meetingID = source.result.meetingID
            let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
            guard let meeting = try? mainContext.fetch(descriptor).first else { continue }
            let around = meeting.segments.segments(around: source.result.sourceID, lead: window, trail: 0)
            guard let last = around.last, last.id == source.result.sourceID, around.count > 1 else { continue }
            result[source.id] = around.dropLast()
                .map { "\($0.speaker.displayName): \($0.text)" }
                .joined(separator: "\n")
        }
        return result
    }

    // MARK: - Mutation helpers

    private var selectedIndex: Int? {
        guard let id = selectedConversationID else { return nil }
        return conversations.firstIndex { $0.id == id }
    }

    private func conversation(_ id: UUID) -> AskConversation? {
        conversations.first { $0.id == id }
    }

    private func ensureConversation(defaultFilter: AskDateFilter) {
        if selectedIndex != nil { return }
        let conversation = AskConversation(
            title: "New conversation",
            dateFilterRaw: defaultFilter.rawValue
        )
        conversations.append(conversation)
        selectedConversationID = conversation.id
    }

    private func updateTurn(_ turnID: UUID, in conversationID: UUID, _ body: (inout AskTurn) -> Void) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == turnID })
        else { return }
        body(&conversations[conversationIndex].turns[turnIndex])
        conversations[conversationIndex].updatedAt = .now
        persist()
    }

    private func failTurn(_ turnID: UUID, in conversationID: UUID, message: String) {
        updateTurn(turnID, in: conversationID) { $0.errorMessage = message }
    }

    private func persist() {
        AskConversationStore.save(conversations)
    }
}
