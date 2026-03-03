#if LOCAL_BUILD
import SwiftUI

/// Settings section for LOCAL_BUILD: check for updates and rebuild from source.
struct LocalBuildUpdateView: View {
    @ObservedObject private var updateService = LocalUpdateService.shared
    @ObservedObject private var buildService = LocalBuildService.shared
    @State private var showSourceDirPicker = false
    @State private var showRebuildConfirmation = false
    @State private var showBuildLog = false
    @State private var showDirtyTreeConfirmation = false
    @State private var validationError: String?

    var body: some View {
        // Source Directory
        sourceDirRow

        if let error = validationError {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(.red)
        }

        // Built Commit
        if let sha = updateService.builtCommitSHA, !sha.isEmpty {
            LabeledContent("Built Commit") {
                Text(String(sha.prefix(7)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }

        // Update Status
        if updateService.updateAvailable {
            updateStatusRow
        } else if updateService.isUpToDate {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("You're up to date")
                    .font(.system(size: 12, weight: .medium))
            }
        }

        if let error = updateService.checkError {
            Text(error)
                .font(.system(size: 11))
                .foregroundColor(.red)
        }

        // Action Buttons
        actionButtons

        // Build State Feedback
        buildFeedback

        // Last check time
        if let lastCheck = updateService.lastCheckDate {
            Text("Last checked: \(lastCheck.formatted(.relative(presentation: .named)))")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Subviews

    private var sourceDirRow: some View {
        LabeledContent("Source Directory") {
            HStack(spacing: 8) {
                if let path = updateService.sourceDirectoryPath {
                    Text(abbreviatePath(path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not configured")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button(updateService.sourceDirectoryPath == nil ? "Select..." : "Change") {
                    showSourceDirPicker = true
                }
                .controlSize(.small)
            }
        }
        .fileImporter(
            isPresented: $showSourceDirPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if let error = updateService.validateSourceDirectory(url.path) {
                    validationError = error
                } else {
                    validationError = nil
                    updateService.setSourceDirectory(url)
                }
            }
        }
    }

    private var updateStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                if updateService.newCommitCount > 0 {
                    Text("\(updateService.newCommitCount) new commit\(updateService.newCommitCount == 1 ? "" : "s") available")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Updates available")
                        .font(.system(size: 12, weight: .medium))
                }
                if let msg = updateService.latestCommitMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                Task { await updateService.checkForUpdates() }
            } label: {
                if updateService.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Check for Updates")
                }
            }
            .disabled(updateService.isChecking || buildService.isBuilding)

            if updateService.sourceDirectoryPath != nil {
                rebuildButton
            }

            if buildService.isBuilding {
                Button("Cancel") {
                    buildService.cancelBuild()
                }
                .foregroundColor(.red)
            }
        }
        .alert("Rebuild VoiceInk?", isPresented: $showRebuildConfirmation) {
            Button("Rebuild") {
                Task { await buildService.startRebuild() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will pull latest upstream changes, rebase your customizations, and rebuild the app.")
        }
        .alert("Uncommitted Changes", isPresented: $showDirtyTreeConfirmation) {
            Button("Discard and Rebuild", role: .destructive) {
                buildService.preflightWarning = nil
                showRebuildConfirmation = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("There are uncommitted changes in the source directory. They will be discarded during the rebuild.\n\nDo you want to continue?")
        }
    }

    @ViewBuilder
    private var buildFeedback: some View {
        switch buildService.buildState {
        case .completed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Build complete!")
                    .font(.system(size: 12, weight: .medium))
                Button("Open New Version") {
                    buildService.openNewVersion()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundColor(.red)
                    Text("Build Failed")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(String(message.prefix(200)) + (message.count > 200 ? "..." : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                HStack(spacing: 8) {
                    Button("Show Full Log") {
                        showBuildLog = true
                    }
                    .controlSize(.small)

                    if buildService.patchFailed {
                        Button("Build without Patches") {
                            Task { await buildService.startRebuild(skipPatches: true) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .sheet(isPresented: $showBuildLog) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Build Log")
                            .font(.headline)
                        Spacer()
                        Button("Close") { showBuildLog = false }
                    }
                    ScrollView {
                        Text(buildService.buildOutput)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(minWidth: 600, minHeight: 400)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rebuildButton: some View {
        let button = Button {
            startRebuildWithPreflight()
        } label: {
            if buildService.isBuilding {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(buildStateLabel)
                }
            } else {
                Text("Rebuild from Latest")
            }
        }
        .disabled(buildService.isBuilding)

        if updateService.updateAvailable {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    // MARK: - Helpers

    private func startRebuildWithPreflight() {
        guard let sourceDir = updateService.sourceDirectoryPath else { return }

        if let error = buildService.runPreflight(sourceDir: sourceDir) {
            buildService.buildState = .failed("Preflight: \(error)")
            return
        }

        if buildService.preflightWarning != nil {
            showDirtyTreeConfirmation = true
        } else {
            showRebuildConfirmation = true
        }
    }

    private var buildStateLabel: String {
        switch buildService.buildState {
        case .preflight: return "Checking..."
        case .pulling: return "Pulling..."
        case .rebasing: return "Rebasing..."
        case .applyingPatches: return "Patching..."
        case .building: return "Building..."
        default: return "Working..."
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
#endif
