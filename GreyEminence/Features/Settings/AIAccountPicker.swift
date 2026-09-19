import AppKit
import SwiftUI

/// Which AWS account one AI feature bills to: the master from Settings →
/// AI, the same as another feature, or a named profile — plus the region,
/// which follows the profile unless overridden. Shows the resolved answer
/// on a line of its own, because "Same as search embeddings" is only
/// meaningful once you can see what that is right now.
struct AIAccountPicker: View {
    let slot: AIAccountSlot
    let profiles: [AWSCredentialLoader.ProfileInfo]
    /// Called after any change, so the host can clear a stale test result.
    var onChange: () -> Void = {}

    @State private var choiceRaw = AIAccountChoice.master.storedValue
    @State private var regionRaw = ""

    private var usableProfiles: [AWSCredentialLoader.ProfileInfo] {
        profiles.filter(\.isSupported)
    }

    private var unusableProfiles: [AWSCredentialLoader.ProfileInfo] {
        profiles.filter { !$0.isSupported }
    }

    private var choice: AIAccountChoice {
        AIAccountChoice(storedValue: choiceRaw) ?? .master
    }

    private var resolved: ResolvedAIAccount {
        AIAccountSettings.resolved(for: slot)
    }

    private var master: ResolvedAIAccount {
        AIAccountSettings.master()
    }

    var body: some View {
        Group {
            controls
        }
        // Seeded here rather than in `init`: `@State` set in an initializer
        // loses its binding, and `@AppStorage` can't express a key that
        // depends on `slot`.
        .onAppear {
            choiceRaw = AIAccountSettings.choice(for: slot).storedValue
            regionRaw = AIAccountSettings.regionOverride(for: slot) ?? ""
        }
    }

    @ViewBuilder
    private var controls: some View {
        Picker("AWS account", selection: $choiceRaw) {
            Text("Main AI account (\(master.profile))").tag(AIAccountChoice.master.storedValue)
            ForEach(AIAccountSlot.allCases.filter { $0 != slot }) { other in
                let target = AIAccountSettings.resolved(for: other)
                Text("Same as \(other.displayName.lowercased()) (\(target.profile))")
                    .tag(AIAccountChoice.sameAs(other).storedValue)
            }
            Divider()
            ForEach(usableProfiles) { info in
                Text("\(info.name) — \(info.kind.reason)").tag(AIAccountChoice.profile(info.name).storedValue)
            }
        }
        .onChange(of: choiceRaw) { _, raw in
            // The seed above also fires this; only a real change writes,
            // or seeding would wipe a stored region override.
            let chosen = AIAccountChoice(storedValue: raw) ?? .master
            guard chosen != AIAccountSettings.choice(for: slot) else { return }
            AIAccountSettings.setChoice(chosen, for: slot)
            // A profile usually declares its own region; adopting it saves
            // the most common misconfiguration, a valid account pointed at
            // a region the model isn't enabled in.
            AIAccountSettings.setRegionOverride(nil, for: slot)
            regionRaw = ""
            onChange()
        }

        if case .profile = choice {
            Picker("Region", selection: $regionRaw) {
                Text("Profile's own (\(resolved.region))").tag("")
                Text("US East (N. Virginia)").tag("us-east-1")
                Text("US East (Ohio)").tag("us-east-2")
                Text("US West (Oregon)").tag("us-west-2")
                Text("EU (Ireland)").tag("eu-west-1")
                Text("EU (Frankfurt)").tag("eu-central-1")
                Text("EU (Paris)").tag("eu-west-3")
                Text("Asia Pacific (Tokyo)").tag("ap-northeast-1")
                Text("Asia Pacific (Sydney)").tag("ap-southeast-2")
            }
            .onChange(of: regionRaw) { _, raw in
                AIAccountSettings.setRegionOverride(raw, for: slot)
                onChange()
            }
        }

        LabeledContent("Uses") {
            Text("\(resolved.profile) · \(resolved.region)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }

        if let helper = helperCommand {
            HStack(spacing: 8) {
                Button("Locate credential helper…") { locateHelper(helper) }
                Text(AWSCredentialLoader.hasHelperAccess(forExecutable: helper.executable)
                     ? "Access granted to \(helper.displayName)."
                     : "This profile runs \(helper.displayName) to fetch credentials. A sandboxed app can only launch a program you've explicitly pointed it at.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !unusableProfiles.isEmpty {
            // Naming these is the point. They were once offered and failed
            // with "profile not found" at the first request, which reads as
            // a bug in the app rather than a property of the profile.
            Text("Not selectable: \(unusableProfiles.map { "\($0.name) (\($0.kind.reason))" }.joined(separator: ", ")).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Credential helpers

    struct HelperCommand {
        let executable: String
        var displayName: String { (executable as NSString).lastPathComponent }
    }

    /// The external helper the resolved profile depends on, if it has one.
    private var helperCommand: HelperCommand? {
        guard let command = AWSCredentialLoader.credentialProcessCommand(profile: resolved.profile),
              let executable = AWSCredentialLoader.tokenizeCommand(command).first else { return nil }
        return HelperCommand(executable: executable)
    }

    private func locateHelper(_ helper: HelperCommand) {
        let panel = NSOpenPanel()
        panel.message = "Select \(helper.displayName) so Grey Eminence can run it for AWS credentials."
        panel.directoryURL = URL(fileURLWithPath: helper.executable).deletingLastPathComponent()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AWSCredentialLoader.persistHelperAccess(to: url)
        onChange()
    }
}
