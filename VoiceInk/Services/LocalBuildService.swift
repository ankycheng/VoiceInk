#if LOCAL_BUILD
import Foundation
import AppKit
import OSLog

/// Manages the rebuild process: preflight checks, git pull, patch, build.
@MainActor
final class LocalBuildService: ObservableObject {
    static let shared = LocalBuildService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LocalBuildService")

    enum BuildState: Equatable {
        case idle
        case preflight
        case pulling
        case rebasing
        case applyingPatches
        case building
        case completed
        case failed(String)
    }

    @Published var buildState: BuildState = .idle
    @Published var buildOutput: String = ""
    @Published var isBuilding: Bool = false

    /// Preflight warning that needs user confirmation before proceeding.
    @Published var preflightWarning: String?
    /// Set to true when patch fails and user can choose to build without patches.
    @Published var patchFailed: Bool = false

    private var buildProcess: Process?
    private let processPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private var workingBranch: String = "main"
    private var isForkWorkflow: Bool { workingBranch != "main" }

    private init() {}

    // MARK: - Public API

    /// Run preflight checks. Returns nil if OK, or an error string.
    func runPreflight(sourceDir: String) -> String? {
        // Validate source directory (also auto-detects upstream remote)
        if let validationError = LocalUpdateService.shared.validateSourceDirectory(sourceDir) {
            return validationError
        }

        let upstreamRemote = LocalUpdateService.shared.upstreamRemoteName

        // Check required tools
        for tool in ["git", "make", "xcodebuild"] {
            let result = runProcess(
                executable: "/usr/bin/which",
                arguments: [tool],
                directory: sourceDir,
                timeout: 5
            )
            if !result.success {
                return "Required tool '\(tool)' not found. Please install it."
            }
        }

        // Detect current branch
        let branchResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            directory: sourceDir,
            timeout: 5
        )
        let branch = branchResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        workingBranch = branch

        // Direct clone mode: must be on main
        if upstreamRemote == "origin" && branch != "main" {
            return "Source is on branch '\(branch)', expected 'main'. Please switch to main first."
        }

        // Check for rebase/merge in progress
        let fm = FileManager.default
        if fm.fileExists(atPath: sourceDir + "/.git/rebase-merge") ||
           fm.fileExists(atPath: sourceDir + "/.git/rebase-apply") ||
           fm.fileExists(atPath: sourceDir + "/.git/MERGE_HEAD") {
            return "A rebase or merge is in progress. Please resolve it before rebuilding."
        }

        // Direct clone mode: check for local commits ahead of remote/main
        if upstreamRemote == "origin" {
            let _ = runProcess(executable: "/usr/bin/git", arguments: ["fetch", upstreamRemote, "main"], directory: sourceDir, timeout: 30)
            let aheadResult = runProcess(
                executable: "/usr/bin/git",
                arguments: ["rev-list", "--count", "\(upstreamRemote)/main..HEAD"],
                directory: sourceDir,
                timeout: 5
            )
            let aheadCount = Int(aheadResult.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if aheadCount > 0 {
                return "You have \(aheadCount) local commit(s) ahead of \(upstreamRemote)/main. These would be lost during rebuild."
            }
        }

        // Check for dirty tree
        let statusResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["status", "--porcelain"],
            directory: sourceDir,
            timeout: 5
        )
        let status = statusResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty {
            preflightWarning = "There are uncommitted changes in the source directory. They will be discarded during rebuild."
            return nil
        }

        preflightWarning = nil
        return nil
    }

    /// Start the rebuild process.
    func startRebuild(skipPatches: Bool = false) async {
        guard !isBuilding else { return }

        guard let sourceDir = LocalUpdateService.shared.sourceDirectoryPath else {
            buildState = .failed("Source directory not configured.")
            return
        }

        isBuilding = true
        buildOutput = ""
        patchFailed = false
        buildState = .preflight

        let result = await Task.detached(priority: .userInitiated) { [sourceDir, skipPatches] in
            await self.executeRebuild(sourceDir: sourceDir, skipPatches: skipPatches)
        }.value

        isBuilding = false

        if case .completed = result {
            // Update the built commit SHA
            LocalUpdateService.shared.withSourceDirectoryAccess { path in
                if let newSHA = LocalUpdateService.shared.readCurrentCommitSHA(from: path) {
                    LocalUpdateService.shared.builtCommitSHA = newSHA
                    LocalUpdateService.shared.updateAvailable = false
                    LocalUpdateService.shared.newCommitCount = 0
                }
            }
        }

        buildState = result
    }

    func cancelBuild() {
        buildProcess?.terminate()
        buildProcess = nil
        isBuilding = false
        buildState = .idle
        buildOutput += "\n[Cancelled by user]\n"
    }

    func openNewVersion() {
        let appPath = "/Applications/VoiceInk.app"
        let appURL = URL(fileURLWithPath: appPath)

        guard FileManager.default.fileExists(atPath: appPath) else {
            buildState = .failed("Built app not found at /Applications/VoiceInk.app")
            return
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { app, error in
            if app != nil {
                // New version launched successfully, terminate old one
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.buildState = .failed("Failed to launch new version: \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    // MARK: - Private

    private func executeRebuild(sourceDir: String, skipPatches: Bool) async -> BuildState {
        if isForkWorkflow {
            return await executeForkRebuild(sourceDir: sourceDir, skipPatches: skipPatches)
        } else {
            return await executeDirectRebuild(sourceDir: sourceDir, skipPatches: skipPatches)
        }
    }

    /// Direct clone path: origin points to Beingpax/VoiceInk, working on main.
    private func executeDirectRebuild(sourceDir: String, skipPatches: Bool) async -> BuildState {
        let upstreamRemote = await MainActor.run { LocalUpdateService.shared.upstreamRemoteName }

        // Step 1: Clean local changes
        await MainActor.run { buildState = .pulling }
        await appendOutput("=== Cleaning local changes ===\n")
        let checkoutResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["checkout", "--", "."],
            directory: sourceDir,
            timeout: 30
        )
        await appendOutput(checkoutResult.output)
        if !checkoutResult.success {
            return .failed("Failed to clean local changes:\n\(checkoutResult.output)")
        }

        // Step 2: git pull
        await appendOutput("\n=== Pulling latest changes ===\n")
        let pullResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["pull", "--rebase", upstreamRemote, "main"],
            directory: sourceDir,
            timeout: 60
        )
        await appendOutput(pullResult.output)
        if !pullResult.success {
            return .failed("git pull failed. You may need to resolve conflicts manually in:\n\(sourceDir)\n\n\(pullResult.output)")
        }

        // Step 3: Apply patches + Step 4: Build
        if let patchError = await applyPatches(sourceDir: sourceDir, skipPatches: skipPatches) {
            return patchError
        }
        return await buildApp(sourceDir: sourceDir)
    }

    /// Fork path: upstream remote is separate, working branch (e.g. "local") rebases onto main.
    private func executeForkRebuild(sourceDir: String, skipPatches: Bool) async -> BuildState {
        let upstreamRemote = await MainActor.run { LocalUpdateService.shared.upstreamRemoteName }
        let branch = workingBranch

        // Step 1: Switch to main and pull upstream
        await MainActor.run { buildState = .pulling }
        await appendOutput("=== Fork workflow: updating main from \(upstreamRemote) ===\n")

        let checkoutMainResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["checkout", "main"],
            directory: sourceDir,
            timeout: 15
        )
        await appendOutput(checkoutMainResult.output)
        if !checkoutMainResult.success {
            // Try to switch back
            let _ = runProcess(executable: "/usr/bin/git", arguments: ["checkout", branch], directory: sourceDir, timeout: 10)
            return .failed("Failed to checkout main:\n\(checkoutMainResult.output)")
        }

        let pullResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["pull", "--rebase", upstreamRemote, "main"],
            directory: sourceDir,
            timeout: 60
        )
        await appendOutput(pullResult.output)
        if !pullResult.success {
            // Switch back to working branch
            let _ = runProcess(executable: "/usr/bin/git", arguments: ["checkout", branch], directory: sourceDir, timeout: 10)
            return .failed("Failed to pull upstream main. Switched back to '\(branch)'.\n\n\(pullResult.output)")
        }

        // Step 2: Switch back to working branch and rebase
        await MainActor.run { buildState = .rebasing }
        await appendOutput("\n=== Rebasing '\(branch)' onto main ===\n")

        let checkoutBranchResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["checkout", branch],
            directory: sourceDir,
            timeout: 15
        )
        await appendOutput(checkoutBranchResult.output)
        if !checkoutBranchResult.success {
            return .failed("Failed to checkout '\(branch)':\n\(checkoutBranchResult.output)")
        }

        let rebaseResult = runProcess(
            executable: "/usr/bin/git",
            arguments: ["rebase", "main"],
            directory: sourceDir,
            timeout: 120
        )
        await appendOutput(rebaseResult.output)
        if !rebaseResult.success {
            await appendOutput("\n=== Rebase failed, aborting to restore clean state ===\n")
            let abortResult = runProcess(
                executable: "/usr/bin/git",
                arguments: ["rebase", "--abort"],
                directory: sourceDir,
                timeout: 15
            )
            await appendOutput(abortResult.output)
            return .failed("Rebase of '\(branch)' onto main failed. Conflicts need manual resolution.\n\n\(rebaseResult.output)")
        }

        // Step 3: Build (skip patches — customizations are already in commits)
        await appendOutput("\n=== Skipping patches (fork workflow: customizations are in commits) ===\n")
        return await buildApp(sourceDir: sourceDir)
    }

    // MARK: - Shared Build Helpers

    private func applyPatches(sourceDir: String, skipPatches: Bool) async -> BuildState? {
        if !skipPatches {
            await MainActor.run { buildState = .applyingPatches }
            await appendOutput("\n=== Applying patches ===\n")

            let patchScript = sourceDir + "/scripts/apply-zh-patches.sh"
            if FileManager.default.fileExists(atPath: patchScript) {
                let patchResult = runProcess(
                    executable: "/bin/bash",
                    arguments: [patchScript],
                    directory: sourceDir,
                    timeout: 30
                )
                await appendOutput(patchResult.output)
                if !patchResult.success {
                    await MainActor.run { patchFailed = true }
                    return .failed("Patch application failed. You can retry with 'Build without patches'.\n\n\(patchResult.output)")
                }
            } else {
                await appendOutput("[Info] No patch script found, skipping.\n")
            }
        } else {
            await appendOutput("\n=== Skipping patches (user choice) ===\n")
        }
        return nil // no error
    }

    private func buildApp(sourceDir: String) async -> BuildState {
        await MainActor.run { buildState = .building }
        await appendOutput("\n=== Building VoiceInk ===\n")
        let buildResult = runProcess(
            executable: "/usr/bin/make",
            arguments: ["local"],
            directory: sourceDir,
            timeout: 600
        )
        await appendOutput(buildResult.output)
        if !buildResult.success {
            return .failed("Build failed:\n\(String(buildResult.output.suffix(500)))")
        }

        let appPath = "/Applications/VoiceInk.app"
        if !FileManager.default.fileExists(atPath: appPath) {
            return .failed("Build completed but VoiceInk.app not found at /Applications/VoiceInk.app")
        }

        return .completed
    }

    private struct ProcessResult {
        let success: Bool
        let output: String
    }

    private func runProcess(executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": processPath,
            "HOME": NSHomeDirectory(),
            "GIT_TERMINAL_PROMPT": "0",
            "LANG": "en_US.UTF-8"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        self.buildProcess = process

        do {
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if process.isRunning {
                process.terminate()
                return ProcessResult(success: false, output: "Command timed out after \(Int(timeout))s.")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ProcessResult(success: process.terminationStatus == 0, output: output)
        } catch {
            return ProcessResult(success: false, output: "Failed to start: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func appendOutput(_ text: String) {
        buildOutput += text
    }
}
#endif
