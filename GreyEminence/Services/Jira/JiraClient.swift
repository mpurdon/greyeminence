import Foundation

/// Where Jira settings live. The API token is a credential, so it goes in
/// the Keychain; the rest are plain preferences.
enum JiraSettings {
    static let siteKey = "jiraSiteURL"
    static let emailKey = "jiraEmail"
    static let projectKey = "jiraProjectKey"
    static let issueTypeKey = "jiraIssueType"
    static let tokenKeychainKey = "jiraAPIToken"

    static let defaultIssueType = "Story"

    struct Credentials: Sendable, Equatable {
        let site: URL
        let email: String
        let token: String
    }

    /// Nil until site, email and token are all present.
    static func credentials() -> Credentials? {
        let defaults = UserDefaults.standard
        guard let site = normalizedSite(defaults.string(forKey: siteKey) ?? ""),
              let email = defaults.string(forKey: emailKey)?.nonEmpty,
              let token = (try? KeychainHelper.get(tokenKeychainKey))??.nonEmpty else { return nil }
        return Credentials(site: site, email: email, token: token)
    }

    static var isConfigured: Bool { credentials() != nil }

    static var defaultProject: String {
        UserDefaults.standard.string(forKey: projectKey)?.nonEmpty?.uppercased() ?? ""
    }

    static var defaultIssueTypeName: String {
        UserDefaults.standard.string(forKey: issueTypeKey)?.nonEmpty ?? defaultIssueType
    }

    /// Accepts what people actually paste: "acme", "acme.atlassian.net",
    /// "https://acme.atlassian.net/jira/software/projects/X/boards/1".
    /// Always an https origin with no path.
    static func normalizedSite(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            if !text.contains(".") { text += ".atlassian.net" }
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        return origin.url
    }
}

/// Jira Cloud REST v3, basic auth with an Atlassian API token.
struct JiraClient: Sendable {
    let credentials: JiraSettings.Credentials

    enum JiraError: LocalizedError {
        case notConfigured
        case http(status: Int, message: String)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Jira isn't set up. Add your site, email and API token in Settings → Jira."
            case .http(let status, let message):
                switch status {
                case 401: "Jira rejected the email or API token (401). \(message)"
                case 403: "Your Jira account can't do that in this project (403). \(message)"
                default: "Jira returned an error (\(status)). \(message)"
                }
            case .unexpectedResponse:
                "Jira sent a response the app couldn't read."
            }
        }
    }

    /// The account's display name — the connection test.
    func myself() async throws -> String {
        let data = try await send("GET", path: "/rest/api/3/myself", body: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["displayName"] as? String else { throw JiraError.unexpectedResponse }
        return name
    }

    func createIssue(
        projectKey: String,
        issueType: String,
        summary: String,
        descriptionMarkdown: String,
        labels: [String] = []
    ) async throws -> JiraIssueLink {
        let body = Self.createIssueBody(
            projectKey: projectKey,
            issueType: issueType,
            summary: summary,
            descriptionMarkdown: descriptionMarkdown,
            labels: labels
        )
        let data = try await send("POST", path: "/rest/api/3/issue", body: body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String else { throw JiraError.unexpectedResponse }
        return JiraIssueLink(key: key, url: Self.browseURL(site: credentials.site, key: key), createdAt: .now)
    }

    // MARK: - Pure helpers (unit-tested)

    static func createIssueBody(
        projectKey: String,
        issueType: String,
        summary: String,
        descriptionMarkdown: String,
        labels: [String]
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "project": ["key": projectKey],
            "issuetype": ["name": issueType],
            // Jira caps summaries at 255 characters and rejects newlines.
            "summary": String(summary.replacingOccurrences(of: "\n", with: " ").prefix(255)),
            "description": JiraADF.document(fromMarkdown: descriptionMarkdown),
        ]
        if !labels.isEmpty { fields["labels"] = labels }
        return ["fields": fields]
    }

    static func browseURL(site: URL, key: String) -> URL {
        site.appendingPathComponent("browse").appendingPathComponent(key)
    }

    /// Jira errors come as `errorMessages` plus a per-field `errors` map
    /// ("issuetype": "Specify a valid issue type"). Both are worth showing.
    static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? ""
        }
        var messages = object["errorMessages"] as? [String] ?? []
        if let fields = object["errors"] as? [String: String] {
            messages += fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        }
        return messages.joined(separator: " ")
    }

    // MARK: - Transport

    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: credentials.site.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        let auth = Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data)
            LogManager.send("Jira \(method) \(path) failed (\(http.statusCode)): \(message)", category: .general, level: .error)
            throw JiraError.http(status: http.statusCode, message: message)
        }
        return data
    }
}

/// Markdown → Atlassian Document Format, for the subset the app writes:
/// headings, bullet lists (one level of nesting), paragraphs, horizontal
/// rules, and **bold** / _italic_ inline. Anything else passes through as
/// text, which Jira shows verbatim — never an error.
enum JiraADF {

    static func document(fromMarkdown markdown: String) -> [String: Any] {
        ["type": "doc", "version": 1, "content": blocks(markdown)]
    }

    static func blocks(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var paragraph: [String] = []
        var list: [[String: Any]] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(["type": "paragraph", "content": inline(paragraph.joined(separator: " "))])
            paragraph = []
        }
        func flushList() {
            guard !list.isEmpty else { return }
            blocks.append(["type": "bulletList", "content": list])
            list = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                flushList()
            } else if let level = headingLevel(line) {
                flushParagraph(); flushList()
                blocks.append([
                    "type": "heading",
                    "attrs": ["level": level],
                    "content": inline(String(line.dropFirst(level + 1))),
                ])
            } else if line == "---" || line == "***" {
                flushParagraph(); flushList()
                blocks.append(["type": "rule"])
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                let item = listItem(String(line.dropFirst(2)))
                if indent >= 2, var parent = list.popLast() {
                    // Nest under the previous item.
                    var content = parent["content"] as? [[String: Any]] ?? []
                    if var nested = content.last, nested["type"] as? String == "bulletList" {
                        var items = nested["content"] as? [[String: Any]] ?? []
                        items.append(item)
                        nested["content"] = items
                        content[content.count - 1] = nested
                    } else {
                        content.append(["type": "bulletList", "content": [item]])
                    }
                    parent["content"] = content
                    list.append(parent)
                } else {
                    list.append(item)
                }
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        flushParagraph()
        flushList()
        return blocks
    }

    private static func listItem(_ text: String) -> [String: Any] {
        ["type": "listItem", "content": [["type": "paragraph", "content": inline(text)]]]
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// Text nodes with strong/em marks. `_` only counts as emphasis at a
    /// word boundary, so snake_case identifiers survive intact.
    static func inline(_ text: String) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        var buffer = ""
        var bold = false
        var italic = false
        let chars = Array(text)

        func flush() {
            guard !buffer.isEmpty else { return }
            var node: [String: Any] = ["type": "text", "text": buffer]
            var marks: [[String: Any]] = []
            if bold { marks.append(["type": "strong"]) }
            if italic { marks.append(["type": "em"]) }
            if !marks.isEmpty { node["marks"] = marks }
            nodes.append(node)
            buffer = ""
        }

        var i = 0
        while i < chars.count {
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                flush()
                bold.toggle()
                i += 2
                continue
            }
            if chars[i] == "_" {
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let opens = !italic && (before == nil || before!.isWhitespace || before == "(") && after != nil && !after!.isWhitespace
                let closes = italic && (after == nil || after!.isWhitespace || after!.isPunctuation)
                if opens || closes {
                    flush()
                    italic.toggle()
                    i += 1
                    continue
                }
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
        // Never an empty text node — ADF rejects those.
        return nodes
    }
}
