import SwiftUI

struct ObsidianSettingsView: View {
    @AppStorage("obsidianVaultPath") private var vaultPath: String = ""
    @AppStorage("obsidianMeetingsFolder") private var meetingsFolder: String = "Meetings"
    @AppStorage("obsidianIncludeTranscript") private var includeTranscript = true
    @AppStorage("obsidianIncludeActionItems") private var includeActionItems = true
    @AppStorage("obsidianIncludeWikilinks") private var includeWikilinks = true

    private var isVaultSelected: Bool { !vaultPath.isEmpty }

    private var vaultName: String {
        URL(fileURLWithPath: vaultPath).lastPathComponent
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    if isVaultSelected {
                        Label(vaultPath, systemImage: "folder.fill")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No vault selected")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose Vault...") {
                        selectVault()
                    }
                }

                HStack {
                    Button("Create New Vault...") {
                        createNewVault()
                    }

                    if isVaultSelected {
                        Spacer()
                        Button("Clear", role: .destructive) {
                            vaultPath = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                LabeledContent("Subfolder name") {
                    TextField("Meetings", text: $meetingsFolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                if isVaultSelected {
                    Text("\(vaultName)/\(meetingsFolder.isEmpty ? "..." : meetingsFolder)/")
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Vault Location", systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Toggle("Include full transcript", isOn: $includeTranscript)
                Toggle("Include action items as checkboxes", isOn: $includeActionItems)
                Toggle("Add [[wikilinks]] for detected topics", isOn: $includeWikilinks)
            } header: {
                Label("Export Options", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                GroupBox {
                    Text(mockMarkdownPreview)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Label("Preview", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Self.restoreVaultAccess()
        }
    }

    // MARK: - Vault Selection

    private func selectVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"

        if panel.runModal() == .OK, let url = panel.url {
            persistVaultAccess(url: url)
        }
    }

    private func createNewVault() {
        let panel = NSSavePanel()
        panel.title = "Create New Obsidian Vault"
        panel.message = "Choose a location and name for your new vault"
        panel.nameFieldStringValue = "My Vault"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                // Create .obsidian subfolder to mark it as an Obsidian vault
                let obsidianDir = url.appendingPathComponent(".obsidian")
                try FileManager.default.createDirectory(at: obsidianDir, withIntermediateDirectories: true)
                persistVaultAccess(url: url)
            } catch {
                // Directory creation failed — silently ignore
            }
        }
    }

    // MARK: - Security-Scoped Bookmark Persistence

    private func persistVaultAccess(url: URL) {
        vaultPath = url.path

        // Save a security-scoped bookmark for sandbox persistence
        if let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmarkData, forKey: "obsidianVaultBookmark")
        }
    }

    static func restoreVaultAccess() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "obsidianVaultBookmark") else {
            return
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        _ = url.startAccessingSecurityScopedResource()

        // Re-persist if bookmark was stale
        if isStale {
            if let newData = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(newData, forKey: "obsidianVaultBookmark")
            }
        }
    }

    // MARK: - Preview

    private var mockMarkdownPreview: String {
        """
        ---
        title: Team Standup
        date: 2024-02-28
        duration: 00:32:15
        tags: [meeting, standup]
        ---

        ## Summary
        Discussion of sprint progress...

        ## Action Items
        - [ ] Review PR #123 @sarah
        - [ ] Update docs @alex

        ## Transcript
        > **Me** (0:00): Good morning...
        > **Sarah** (0:15): Thanks...
        """
    }
}
