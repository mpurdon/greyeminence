import SwiftData
import SwiftUI

/// Prompts to put names to the voices a meeting couldn't identify.
///
/// Sits above the transcript because that's where you're reading when you
/// realise Speaker 2 is Gene. Naming one here does two things: relabels this
/// meeting, and teaches the voice, so the next meeting recognises them without
/// being asked.
struct SpeakerIdentityBar: View {
    let meeting: Meeting
    /// Bumped by the parent after an edit so the list recomputes.
    var refreshToken: Int = 0
    /// Show only this voice's lines in the transcript. The point of naming a
    /// voice is listening to it first, and a minute of speech in a two-hour
    /// call is otherwise unfindable.
    var onFilterSpeaker: ((String) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var picking: SpeakerIdentityService.Unidentified?
    @State private var speakers: [SpeakerIdentityService.Unidentified] = []

    var body: some View {
        // A container that always exists. Wrapping this in a `Group` whose
        // only child is a condition means SwiftUI elides the whole view when
        // the condition is false — taking `.task` with it, so the list never
        // loads and the bar never appears.
        VStack(alignment: .leading, spacing: 0) {
            if !speakers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.wave.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(speakers.count == 1 ? "One voice isn't identified" : "\(speakers.count) voices aren't identified")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(speakers) { speaker in
                                chip(speaker)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // `refreshToken` already covers relabels, which don't change the
        // segment count anyway — and reading `segments.count` on every view
        // update faults the whole relationship.
        .task(id: "\(meeting.id)-\(refreshToken)") { reload() }
        .popover(item: $picking) { speaker in
            ContactPicker(
                excludedContacts: [],
                prioritizedContacts: meeting.presentAttendees
            ) { contact in
                SpeakerIdentityService.identify(
                    label: speaker.label,
                    as: contact,
                    in: meeting,
                    context: modelContext
                )
                picking = nil
                reload()
            }
        }
    }

    @ViewBuilder
    private func chip(_ speaker: SpeakerIdentityService.Unidentified) -> some View {
        HStack(spacing: 2) {
            identifyButton(speaker)
            if let onFilterSpeaker {
                Button {
                    onFilterSpeaker(speaker.label)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show only this voice's lines, so you can listen before naming them")
            }
        }
    }

    @ViewBuilder
    private func identifyButton(_ speaker: SpeakerIdentityService.Unidentified) -> some View {
        Button {
            picking = speaker
        } label: {
            HStack(spacing: 5) {
                Text(speaker.label)
                    .font(.caption.weight(.semibold))
                Text(duration(speaker.seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let suggestion = speaker.suggestion {
                    Divider().frame(height: 10)
                    // A suggestion, never an assertion — the name is only
                    // applied when you choose it.
                    Text(suggestion.profile.contactName)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text("\(Int(suggestion.similarity * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if !speaker.hasSignature {
                    // Worth saying: naming this one fixes the transcript but
                    // teaches nothing, because there's no voice to learn from.
                    Image(systemName: "waveform.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Recorded before voices were captured — naming this won't help recognise them elsewhere")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                speaker.suggestion == nil
                    ? AnyShapeStyle(Color.secondary.opacity(0.1))
                    : AnyShapeStyle(Color.accentColor.opacity(0.12)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(speaker.suggestion.map { "Might be \($0.profile.contactName) — \(Int($0.similarity * 100))% similar. Click to choose." }
              ?? "Click to say who this is")
    }

    private func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }

    private func reload() {
        speakers = SpeakerIdentityService.unidentifiedSpeakers(in: meeting)
    }
}
