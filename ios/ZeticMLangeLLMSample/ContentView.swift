import PhotosUI
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = VisionChatViewModel()
    @StateObject private var modelDownload = VisionModelDownloadCoordinator()
    @StateObject private var network = NetworkPathObserver()

    @State private var showCamera = false
    @State private var librarySelection: PhotosPickerItem?
    @State private var pickerFailure: String?
    @State private var showZoom = false
    @State private var pendingReplacement: UIImage?
    @State private var hasDeferredModelDownload = false
    @State private var isRemoveDownloadedModelConfirmationPresented = false
    @State private var modelRemovalMessage: String?
    @FocusState private var questionFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if !modelDownload.hasDownloadConsent && !hasDeferredModelDownload {
                    modelDownloadConsentView
                } else if !modelDownload.hasDownloadConsent {
                    modelNotDownloadedView
                } else if let failure = modelDownload.failureMessage {
                    backgroundDownloadFailureView(failure)
                } else if modelDownload.isBackgroundDownloadInProgress {
                    backgroundDownloadView
                } else if let failure = viewModel.loadFailure {
                    loadFailureView(failure)
                } else if !viewModel.isModelReady {
                    loadingView
                } else {
                    mainView
                }
            }
            .navigationTitle("Ask about a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { modelSettingsMenu }
        }
        .task {
            modelDownload.resumeIfConsented()
            await loadInstalledModelIfNeeded()
        }
        .onChange(of: modelDownload.phase) { _, phase in
            guard phase == .installed else { return }
            Task { await loadInstalledModelIfNeeded() }
        }
        .onDisappear { viewModel.cleanUp() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { propose($0) }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showZoom) {
            if let image = viewModel.image {
                ZoomableImageView(image: image)
            }
        }
        .onChange(of: librarySelection) { _, item in
            guard let item else { return }
            Task { await loadFromLibrary(item) }
        }
        .alert("Could not load that photo", isPresented: alertBinding) {
            Button("OK") { pickerFailure = nil }
        } message: {
            Text(pickerFailure ?? "")
        }
        .alert("Replace this photo?", isPresented: replacementBinding) {
            Button("Replace", role: .destructive) {
                if let pending = pendingReplacement { viewModel.select(pending) }
                pendingReplacement = nil
            }
            Button("Keep current", role: .cancel) { pendingReplacement = nil }
        } message: {
            Text("The answers for the current photo will be cleared.")
        }
        .confirmationDialog(
            "Remove downloaded model?",
            isPresented: $isRemoveDownloadedModelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive, action: removeDownloadedModel)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the downloaded vision model. Your photos and conversations stay on this phone.")
        }
        .alert("Model storage", isPresented: modelRemovalAlertBinding) {
            Button("OK") { modelRemovalMessage = nil }
        } message: {
            Text(modelRemovalMessage ?? "")
        }
    }

    /// A real binding — `.constant(...)` left the alert unable to clear its own state
    /// when the system dismissed it.
    private var alertBinding: Binding<Bool> {
        Binding(get: { pickerFailure != nil }, set: { if !$0 { pickerFailure = nil } })
    }

    private var replacementBinding: Binding<Bool> {
        Binding(get: { pendingReplacement != nil }, set: { if !$0 { pendingReplacement = nil } })
    }

    private var modelRemovalAlertBinding: Binding<Bool> {
        Binding(get: { modelRemovalMessage != nil }, set: { if !$0 { modelRemovalMessage = nil } })
    }

    // MARK: - Load states

    private var modelDownloadConsentView: some View {
        ContentUnavailableView {
            Label("Download the vision model?", systemImage: "arrow.down.circle")
        } description: {
            Text("The model is downloaded in the background after you agree. It may use 1–2 GB of data and storage, and stays only on this phone.")
        } actions: {
            Button("Download model") { modelDownload.recordConsent() }
                .buttonStyle(.borderedProminent)
            Button("Not now") { hasDeferredModelDownload = true }
        }
    }

    private var modelNotDownloadedView: some View {
        ContentUnavailableView {
            Label("Vision model required", systemImage: "arrow.down.circle")
        } description: {
            Text("Download the on-device model when you are ready to ask about a photo.")
        } actions: {
            Button("Download model") { hasDeferredModelDownload = false }
                .buttonStyle(.borderedProminent)
        }
    }

    private var backgroundDownloadView: some View {
        VStack(spacing: 18) {
            if case let .downloading(progress) = modelDownload.phase, let progress {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
            } else {
                ProgressView()
            }

            VStack(spacing: 6) {
                Text(modelDownload.phase.title)
                    .font(.headline)
                    .accessibilityIdentifier("background-model-download-headline")
                if let detail = modelDownload.phase.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("background-model-download-detail")
                }
            }

            Text("You can keep this app open or leave it. Asking about a photo will be available when the download finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if network.isExpensive || network.isConstrained {
                Label(
                    network.isConstrained
                        ? "Low Data Mode is on — connect to Wi-Fi to avoid a slow or interrupted download."
                        : "You're on cellular. This download is large — Wi-Fi is strongly recommended.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 28)
            }
        }
        .padding()
    }

    private func backgroundDownloadFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Model download unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { modelDownload.retry() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            if viewModel.loadPhase == .downloading {
                ProgressView(value: viewModel.downloadProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 260)
            } else {
                ProgressView()
            }

            VStack(spacing: 6) {
                Text(viewModel.loadPhase == .downloading
                     ? "Downloading model — \(Int(viewModel.downloadProgress * 100))%"
                     : "Initializing model…")
                    .font(.headline)

                Text(timingText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(viewModel.loadPhase == .downloading
                 ? "The first run may download roughly 1–2 GB. Later launches reuse available SDK-managed model cache."
                 : "Preparing the on-device model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            if viewModel.loadPhase == .downloading && (network.isExpensive || network.isConstrained) {
                Label(
                    network.isConstrained
                        ? "Low Data Mode is on — connect to Wi-Fi to avoid a slow or interrupted download."
                        : "You're on cellular. This download is large — Wi-Fi is strongly recommended.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 28)
            }
        }
        .padding()
    }

    private var timingText: String {
        let elapsed = "\(viewModel.elapsedSeconds / 60)m \(viewModel.elapsedSeconds % 60)s elapsed"
        guard viewModel.loadPhase == .downloading, let remaining = viewModel.estimatedSecondsRemaining else {
            return elapsed
        }
        return "\(elapsed) · about \(remaining / 60)m \(remaining % 60)s left"
    }

    private func loadFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Model unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { viewModel.retryLoad() }
                .buttonStyle(.borderedProminent)
        }
    }

    @ToolbarContentBuilder
    private var modelSettingsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Remove downloaded model", role: .destructive, action: requestDownloadedModelRemoval)
                    .disabled(modelDownload.isRemoving)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Model settings")
        }
    }

    private func loadInstalledModelIfNeeded() async {
        guard modelDownload.canUseDownloadedModel else { return }
        await viewModel.loadModel()
    }

    private func requestDownloadedModelRemoval() {
        guard modelDownload.isBackgroundDownloadInProgress || viewModel.canRemoveDownloadedModel else {
            modelRemovalMessage = "Finish the current answer or model preparation before removing the downloaded model."
            return
        }
        isRemoveDownloadedModelConfirmationPresented = true
    }

    private func removeDownloadedModel() {
        Task {
            if !modelDownload.isBackgroundDownloadInProgress,
               !(await viewModel.closeModelForRemoval()) {
                modelRemovalMessage = "Finish the current answer or model preparation before removing the downloaded model."
                return
            }

            switch await modelDownload.removeDownloadedModel() {
            case .removed:
                hasDeferredModelDownload = false
                modelRemovalMessage = "The downloaded model was removed. Downloading it again will require your approval."
            case .inUse:
                modelRemovalMessage = "Finish the current answer before removing the downloaded model."
            case let .failed(message):
                modelRemovalMessage = message
            }
        }
    }

    // MARK: - Main

    private var mainView: some View {
        VStack(spacing: 0) {
            imageSection
            if viewModel.image != nil {
                suggestionRow
            }
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var imageSection: some View {
        Group {
            if let image = viewModel.image {
                VStack(spacing: 8) {
                    Button {
                        showZoom = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Selected photo. Double-tap to view full screen.")

                    // Controls sit below the photo rather than on top of it.
                    HStack(spacing: 10) {
                        sourceButtons
                        Spacer()
                        Text("Model sees \(Int(Constants.maxImageDimension)) px")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("Take a photo or choose one from your library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    sourceButtons
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
            }
        }
    }

    private var sourceButtons: some View {
        HStack(spacing: 10) {
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            PhotosPicker(selection: $librarySelection, matching: .images, photoLibrary: .shared()) {
                Label("Library", systemImage: "photo.fill")
            }
            .buttonStyle(.bordered)
        }
        .labelStyle(.titleAndIcon)
        .font(.footnote)
    }

    /// One-tap questions — the keyboard is the slowest part of asking on a phone.
    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Constants.Prompt.suggestions, id: \.self) { suggestion in
                    Button {
                        questionFocused = false
                        viewModel.ask(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(.systemGray6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGenerating || !viewModel.isModelReady)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.turns.enumerated()), id: \.element.id) { index, turn in
                        AnswerBubble(
                            turn: turn,
                            isLast: index == viewModel.turns.count - 1,
                            onRegenerate: { viewModel.regenerateLast() }
                        )
                        .id(turn.id)
                    }
                }
                .padding(.vertical, 8)
            }
            // Animate when a turn is added; scroll plainly while tokens stream, so
            // per-token animations don't fight each other.
            .onChange(of: viewModel.turns.count) { _, _ in
                scroll(proxy, animated: !reduceMotion)
            }
            .onChange(of: viewModel.turns.last?.answer) { _, _ in
                scroll(proxy, animated: false)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { questionFocused = false })
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = viewModel.turns.last else { return }
        if animated {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this image", text: $viewModel.question, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .focused($questionFocused)
                .disabled(viewModel.image == nil)
                .onSubmit(send)

            if viewModel.isGenerating {
                Button {
                    viewModel.cancelGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!viewModel.canAsk)
                .accessibilityLabel("Send question")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func send() {
        questionFocused = false
        viewModel.ask()
    }

    /// Selecting a new photo discards the current answers, so ask first when there
    /// is something to lose.
    private func propose(_ image: UIImage) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if viewModel.hasTranscript {
            pendingReplacement = image
        } else {
            viewModel.select(image)
        }
    }

    private func loadFromLibrary(_ item: PhotosPickerItem) async {
        defer { librarySelection = nil }
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                pickerFailure = "That file could not be read as an image."
                return
            }
            propose(image)
        } catch {
            pickerFailure = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
