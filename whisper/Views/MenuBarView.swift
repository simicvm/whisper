import SwiftUI

/// The dropdown content shown when clicking the menu bar icon.
struct MenuBarView: View {
    @Bindable var appState: AppState
    var onModelSelect: (STTModelDefinition) -> Void
    var onDeleteLocalModel: (STTModelDefinition) -> Void
    var onHotkeyPresetSelect: (ModifierHotkeyPreset) -> Void
    var runOnStartupEnabled: Bool
    var onRunOnStartupToggle: () -> Void
    var onRequestMicrophonePermission: () -> Void
    var onRequestAccessibilityPermission: () -> Void
    var onRecheckPermissions: () -> Void
    var onQuit: () -> Void

    @State private var hoveredModelID: String?
    @State private var hoveredDeleteModelID: String?
    @State private var hoveredDownloadModelID: String?
    @State private var isHoveringRunOnStartup = false
    @State private var isHoveringQuit = false
    private let infoLabelWidth: CGFloat = 94

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSection
            Divider().padding(.horizontal, 2)

            modelSection

            if case .downloading(let progress) = appState.modelStatus {
                ProgressView(value: progress)
                    .padding(.horizontal, 2)
            }

            Divider().padding(.horizontal, 2)
            infoSection

            Divider().padding(.horizontal, 2)
            startupSection
            quitSection
        }
        .padding(10)
        .frame(width: 300)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.menuStatusColor)
                    .frame(width: 9, height: 9)
                Text(appState.menuStatusLabel)
                    .font(.system(.body, weight: .semibold))
            }

            if appState.shouldShowStatusDetail {
                Text(appState.statusText)
                    .font(.system(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var modelSection: some View {
        Text("Model")
            .font(.system(.caption))
            .foregroundStyle(.secondary)

        ForEach(STTModelDefinition.allModels) { model in
            let isDownloaded = appState.downloadedModelRepoIDs.contains(model.repoID)
            let isSelectedDownloadedModel =
                appState.selectedModelID == model.repoID && isDownloaded
            let isHoveringDelete = hoveredDeleteModelID == model.repoID
            let isHoveringDownload = hoveredDownloadModelID == model.repoID

            HStack(spacing: 6) {
                Button {
                    onModelSelect(model)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(.caption, weight: .semibold))
                            .opacity(isSelectedDownloadedModel ? 1 : 0)
                        Text(model.displayName)
                            .font(.system(.body))

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hoveredModelID == model.repoID ? Color.primary.opacity(0.1) : .clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
                .disabled(isModelInteractionDisabled)
                .onHover { isHovering in
                    if isHovering {
                        hoveredModelID = model.repoID
                    } else if hoveredModelID == model.repoID {
                        hoveredModelID = nil
                    }
                }

                if isDownloaded {
                    Button {
                        onDeleteLocalModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(isHoveringDelete ? .red : .secondary)
                            .frame(width: 18, height: 18)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isHoveringDelete ? Color.red.opacity(0.14) : .clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isModelInteractionDisabled)
                    .help("Delete local model files")
                    .onHover { isHovering in
                        if isHovering {
                            hoveredDeleteModelID = model.repoID
                        } else if hoveredDeleteModelID == model.repoID {
                            hoveredDeleteModelID = nil
                        }
                    }
                } else {
                    Button {
                        onModelSelect(model)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(isHoveringDownload ? .blue : .secondary)
                            .frame(width: 18, height: 18)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isHoveringDownload ? Color.blue.opacity(0.16) : .clear)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isModelInteractionDisabled)
                    .help("Download model")
                    .onHover { isHovering in
                        if isHovering {
                            hoveredDownloadModelID = model.repoID
                        } else if hoveredDownloadModelID == model.repoID {
                            hoveredDownloadModelID = nil
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Push to Talk") {
                Picker("Push to Talk", selection: hotkeySelectionBinding) {
                    ForEach(ModifierHotkeyPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 165, alignment: .trailing)
                .disabled(appState.phase != .idle)
            }

            if let hotkeySettingsMessage = appState.hotkeySettingsMessage {
                Text(hotkeySettingsMessage)
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }

            permissionRow("Mic", status: appState.microphonePermission)
            permissionRow("Accessibility", status: appState.accessibilityPermission)

            if !appState.hasRequiredPermissions {
                permissionActionsSection
            }
        }
    }

    @ViewBuilder
    private var permissionActionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.microphonePermission != .granted {
                Button(appState.microphonePermission == .denied ? "Open Microphone Settings" : "Request Microphone Access") {
                    onRequestMicrophonePermission()
                }
                .font(.system(.caption, weight: .medium))
            }

            if appState.accessibilityPermission != .granted {
                Button("Open Accessibility Settings") {
                    onRequestAccessibilityPermission()
                }
                .font(.system(.caption, weight: .medium))
            }

            Button("Re-check Permissions") {
                onRecheckPermissions()
            }
            .font(.system(.caption, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onRunOnStartupToggle()
            } label: {
                HStack(spacing: 6) {
                    if runOnStartupEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    Text("Run on Startup")
                        .font(.system(.body))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHoveringRunOnStartup ? Color.primary.opacity(0.1) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovering in
                isHoveringRunOnStartup = isHovering
            }

            if let error = appState.runOnStartupError {
                Text(error)
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder
    private var quitSection: some View {
        Button {
            onQuit()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(.caption))
                Text("Quit Whisper")
                    .font(.system(.body))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHoveringQuit ? Color.primary.opacity(0.1) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
        .onHover { isHovering in
            isHoveringQuit = isHovering
        }
    }

    @ViewBuilder
    private func infoRow<Content: View>(label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
                .frame(width: infoLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func permissionRow(_ name: String, status: PermissionStatus) -> some View {
        let granted = status == .granted

        return HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(granted ? .green : .red)
            Text(name)
                .font(.system(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(permissionLabel(for: status))
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(granted ? .green : .orange)
        }
        .padding(.horizontal, 6)
    }

    private func permissionLabel(for status: PermissionStatus) -> String {
        switch status {
        case .granted:
            return "Granted"
        case .unknown:
            return "Unknown"
        case .denied:
            return "Missing"
        }
    }

    private var hotkeySelectionBinding: Binding<ModifierHotkeyPreset> {
        Binding(
            get: { appState.hotkeyPreset },
            set: { preset in
                onHotkeyPresetSelect(preset)
            }
        )
    }

    private var isModelInteractionDisabled: Bool {
        switch appState.phase {
        case .recording, .transcribing, .pasting:
            return true
        default:
            return false
        }
    }

}
