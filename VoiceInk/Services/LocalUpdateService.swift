#if LOCAL_BUILD
import Foundation
import OSLog

/// Checks GitHub for new commits vs. the locally-built commit SHA.
@MainActor
final class LocalUpdateService: ObservableObject {
    static let shared = LocalUpdateService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalUpdateService")

    // MARK: - Published State
    @Published var isChecking = false
    @Published var isUpToDate = false
    @Published var updateAvailable = false
    @Published var latestCommitSHA: String?
    @Published var latestCommitMessage: String?
    @Published var latestCommitDate: Date?
    @Published var newCommitCount: Int = 0
    @Published var lastCheckDate: Date?
    @Published var checkError: String?
    @Published var upstreamRemoteName: String = "origin"

    // MARK: - Configuration
    private let defaults = UserDefaults.standard
    private let repoOwner = "Beingpax"
    private let repoName = "VoiceInk"
    private let defaultBranch = "main"

    /// ETag from last GitHub API response for caching.
    private var cachedETag: String?

    /// Timer for periodic auto-check.
    private var autoCheckTimer: Timer?

    var builtCommitSHA: String? {
        get { defaults.string(forKey: "LocalBuild_BuiltCommitSHA") }
        set { defaults.set(newValue, forKey: "LocalBuild_BuiltCommitSHA") }
    }

    // MARK: - Source Directory with Security-Scoped Bookmark

    var sourceDirectoryPath: String? {
        get {
            guard let bookmarkData = defaults.data(forKey: "LocalBuild_SourceDirBookmark") else {
                return defaults.string(forKey: "LocalBuild_SourceDirectoryPath")
            }
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                return nil
            }
            if isStale {
                saveSourceDirectoryBookmark(url)
            }
            return url.path
        }
    }

    func setSourceDirectory(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        defaults.set(url.path, forKey: "LocalBuild_SourceDirectoryPath")
        saveSourceDirectoryBookmark(url)
        url.stopAccessingSecurityScopedResource()

        // Auto-detect built SHA
        if let sha = readCurrentCommitSHA(from: url.path) {
            builtCommitSHA = sha
        }
    }

    private func saveSourceDirectoryBookmark(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: "LocalBuild_SourceDirBookmark")
        }
    }

    /// Access the source directory with security scope for operations.
    func withSourceDirectoryAccess<T>(_ block: (String) -> T) -> T? {
        guard let bookmarkData = defaults.data(forKey: "LocalBuild_SourceDirBookmark") else {
            if let path = defaults.string(forKey: "LocalBuild_SourceDirectoryPath") {
                return block(path)
            }
            return nil
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return block(url.path)
    }

    private init() {
        startAutoCheckTimer()
    }

    private func startAutoCheckTimer() {
        autoCheckTimer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkForUpdates()
            }
        }
    }

    // MARK: - Check for Updates

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        checkError = nil
        isUpToDate = false
        updateAvailable = false
        newCommitCount = 0
        defer { isChecking = false }

        // Auto-detect SHA if needed
        if builtCommitSHA == nil {
            _ = withSourceDirectoryAccess { path in
                builtCommitSHA = readCurrentCommitSHA(from: path)
            }
        }

        guard let builtSHA = builtCommitSHA else {
            checkError = "No built commit SHA found. Set your source directory first."
            return
        }

        do {
            guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/commits?sha=\(defaultBranch)&per_page=1") else { return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("VoiceInk-LocalBuild/1.0", forHTTPHeaderField: "User-Agent")
            if let etag = cachedETag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                checkError = "Invalid response from GitHub."
                return
            }

            if httpResponse.statusCode == 304 {
                // Not modified — re-derive state from cached data
                lastCheckDate = Date()
                if let cachedSHA = latestCommitSHA, cachedSHA != builtSHA {
                    updateAvailable = true
                    await fetchCommitCount(since: builtSHA)
                } else {
                    isUpToDate = true
                }
                return
            }

            if httpResponse.statusCode == 403 {
                checkError = "GitHub API rate limit exceeded. Try again later."
                return
            }

            guard httpResponse.statusCode == 200 else {
                checkError = "GitHub API error (HTTP \(httpResponse.statusCode))."
                return
            }

            // Cache ETag
            cachedETag = httpResponse.value(forHTTPHeaderField: "ETag")

            let commits = try JSONDecoder().decode([GitHubCommit].self, from: data)
            guard let latest = commits.first else {
                checkError = "No commits found."
                return
            }

            latestCommitSHA = latest.sha
            latestCommitMessage = latest.commit.message.components(separatedBy: "\n").first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            latestCommitDate = formatter.date(from: latest.commit.committer.date)
            lastCheckDate = Date()

            if latest.sha != builtSHA {
                updateAvailable = true
                await fetchCommitCount(since: builtSHA)
            } else {
                isUpToDate = true
            }
        } catch is URLError {
            checkError = "Network error. Check your internet connection."
        } catch {
            checkError = "Error: \(error.localizedDescription)"
            logger.error("Update check failed: \(error.localizedDescription)")
        }
    }

    private func fetchCommitCount(since sha: String) async {
        do {
            guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/compare/\(sha)...\(defaultBranch)") else { return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("VoiceInk-LocalBuild/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                // Fallback: just show "updates available" without count
                newCommitCount = 0
                return
            }
            let comparison = try JSONDecoder().decode(GitHubComparison.self, from: data)
            newCommitCount = comparison.aheadBy
        } catch {
            newCommitCount = 0
        }
    }

    // MARK: - Git Helpers

    func readCurrentCommitSHA(from directoryPath: String) -> String? {
        let result = runGitCommand(["rev-parse", "HEAD"], in: directoryPath, timeout: 10)
        return result.success ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func validateSourceDirectory(_ path: String) -> String? {
        // Check directory exists
        guard FileManager.default.fileExists(atPath: path) else {
            return "Directory does not exist."
        }
        // Check it's a git repo
        guard FileManager.default.fileExists(atPath: path + "/.git") else {
            return "Not a git repository."
        }
        // Check Makefile exists
        guard FileManager.default.fileExists(atPath: path + "/Makefile") else {
            return "No Makefile found."
        }
        // Auto-detect which remote points to Beingpax/VoiceInk
        if let detected = detectUpstreamRemote(in: path) {
            upstreamRemoteName = detected
        } else {
            return "No remote pointing to Beingpax/VoiceInk found. Add one with:\n  git remote add upstream https://github.com/Beingpax/VoiceInk.git"
        }
        return nil // Valid
    }

    /// Scan all remotes to find the one pointing to Beingpax/VoiceInk.
    /// Returns the remote name (e.g. "origin" or "upstream"), or nil if not found.
    private func detectUpstreamRemote(in directory: String) -> String? {
        let result = runGitCommand(["remote", "-v"], in: directory, timeout: 5)
        guard result.success else { return nil }

        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("(fetch)") else { continue }
            let lowered = trimmed.lowercased()
            if lowered.contains("beingpax/voiceink") {
                // First token is the remote name
                let name = trimmed.components(separatedBy: .whitespaces).first
                if let name, !name.isEmpty {
                    return name
                }
            }
        }
        return nil
    }

    private func runGitCommand(_ arguments: [String], in directory: String, timeout: TimeInterval) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                return (false, "Command timed out.")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, "Failed to run: \(error.localizedDescription)")
        }
    }
}

// MARK: - GitHub API Models

private struct GitHubCommit: Decodable {
    let sha: String
    let commit: GitHubCommitDetail
}

private struct GitHubCommitDetail: Decodable {
    let message: String
    let committer: GitHubCommitter
}

private struct GitHubCommitter: Decodable {
    let date: String
}

private struct GitHubComparison: Decodable {
    let aheadBy: Int
    enum CodingKeys: String, CodingKey {
        case aheadBy = "ahead_by"
    }
}
#endif
