//
//  ContentView.swift
//  sorbfisch
//
//  Created by Karl Georg Josef Baier on 05.10.26.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = LiveTranslationViewModel()
    @State private var isShowingLegalInformation = false
    @State private var isConfirmingModelDeletion = false
    @State private var modelStorageResultMessage = ""
    @State private var isExportingTranscript = false
    @State private var transcriptDocument = TranscriptDocument(text: "")
    @State private var transcriptFilename = "Sorbfisch"
    @State private var isShowingExportError = false
    @State private var exportErrorMessage = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        languageRoute
                        translationCard
                        recordingControls
                        privacyNote
                        Button {
                            isShowingLegalInformation = true
                        } label: {
                            Label("Impressum & Datenschutz", systemImage: "info.circle")
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Sorbfisch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("NavigationIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)

                        Text("Sorbfisch")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    modelStatus
                }
            }
        }
        .tint(.blue)
        .sheet(isPresented: $isShowingLegalInformation) {
            legalInformationSheet
        }
        .fileExporter(
            isPresented: $isExportingTranscript,
            document: transcriptDocument,
            contentType: .plainText,
            defaultFilename: transcriptFilename
        ) { result in
            if case .failure(let error) = result {
                let cocoaError = error as NSError
                guard cocoaError.domain != NSCocoaErrorDomain
                    || cocoaError.code != CocoaError.Code.userCancelled.rawValue else { return }
                exportErrorMessage = error.localizedDescription
                isShowingExportError = true
            }
        }
        .alert("Export fehlgeschlagen", isPresented: $isShowingExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportErrorMessage)
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if !targetEnvironment(macCatalyst)
            if !ProcessInfo.processInfo.isiOSAppOnMac, newPhase != .active {
                viewModel.stopRecording()
            }
            #endif
        }
        .onDisappear {
            viewModel.stopRecording()
        }
        .alert("Etwas ist schiefgelaufen", isPresented: $viewModel.isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unbekannter Fehler")
        }
    }

    private var languageRoute: some View {
        HStack(spacing: 14) {
            languageLabel(code: "HSB", name: "Hornjoserbsce")

            Image(systemName: "arrow.right")
                .font(.headline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Menu {
                ForEach(OutputLanguage.allCases) { language in
                    Button {
                        Task { await viewModel.selectOutputLanguage(language) }
                    } label: {
                        if language == viewModel.outputLanguage {
                            Label(language.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(language.menuTitle)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    languageLabel(code: viewModel.outputLanguage.rawValue, name: viewModel.outputLanguage.name)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canChangeOutputLanguage)
            .accessibilityLabel("Ausgabesprache")
            .accessibilityValue(viewModel.outputLanguage.menuTitle)
            .accessibilityHint("Deutsch für Übersetzung oder Obersorbisch für Diktat wählen. Aufnahme vorher stoppen.")
        }
        .padding(.vertical, 10)
    }

    private func languageLabel(code: String, name: String) -> some View {
        VStack(spacing: 5) {
            Text(code)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.blue.opacity(0.11), in: Capsule())

            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(viewModel.outputLanguage.outputTitle, systemImage: "text.bubble")
                    .font(.headline)

                Spacer()

                if let confidence = viewModel.confidence {
                    confidenceBadge(confidence)
                }
            }

            Group {
                if viewModel.translatedText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: viewModel.isRecording ? "waveform" : "quote.bubble")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, isActive: viewModel.isRecording)

                        Text(viewModel.emptyStateMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if viewModel.modelState == .loading, !viewModel.isDownloading {
                            ProgressView()
                                .accessibilityLabel(viewModel.controlHint)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Text(viewModel.translatedText)
                        .font(.system(.title3, design: .rounded, weight: .regular))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                }
            }

            if viewModel.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sprachmodell herunterladen")
                        Spacer()
                        Text(viewModel.downloadProgress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.footnote.weight(.medium))
                    ProgressView(value: viewModel.downloadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Modelldownload")
                    Text("\(viewModel.outputLanguage.modelResource) · Hugging Face\nNach dem Download auch offline verfügbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Label(viewModel.statusMessage, systemImage: viewModel.statusSymbol)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(viewModel.isRecording ? .red : .secondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    viewModel.copyTranslation()
                } label: {
                    Image(systemName: viewModel.didCopy ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.translatedText.isEmpty)
                .accessibilityLabel(viewModel.outputLanguage == .german ? "Übersetzung kopieren" : "Diktat kopieren")

                Button {
                    exportTranscript()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.translatedText.isEmpty)
                .accessibilityLabel("Transkript als Textdatei speichern")
                .help("Transkript als .txt-Datei speichern")
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.045), radius: 18, y: 8)
    }

    private func exportTranscript() {
        guard !viewModel.translatedText.isEmpty else { return }
        // Capture a snapshot so ongoing transcription cannot change the export.
        transcriptDocument = TranscriptDocument(text: viewModel.translatedText)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        transcriptFilename = "Sorbfisch-\(viewModel.outputLanguage.rawValue)-\(formatter.string(from: Date()))"
        isExportingTranscript = true
    }

    private func confidenceBadge(_ confidence: Double) -> some View {
        let color: Color = confidence >= 0.75 ? .green : confidence >= 0.5 ? .orange : .red

        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(confidence, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Modellkonfidenz \(confidence.formatted(.percent.precision(.fractionLength(0))))")
    }

    private var recordingControls: some View {
        VStack(spacing: 18) {
            WaveformView(levels: viewModel.audioLevels, isActive: viewModel.isRecording)
                .frame(height: 44)
                .padding(.horizontal, 28)

            Button {
                Task { await viewModel.toggleRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(viewModel.isRecording ? Color.red : Color.blue)
                        .frame(width: 76, height: 76)
                        .shadow(
                            color: (viewModel.isRecording ? Color.red : Color.blue).opacity(0.28),
                            radius: 14,
                            y: 6
                        )

                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRecord)
            .opacity(viewModel.canRecord ? 1 : 0.55)
            .accessibilityLabel(recordingControlAccessibilityLabel)

            Text(viewModel.controlHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .animation(.default, value: viewModel.controlHint)
        }
        .padding(.top, 2)
    }

    private var privacyNote: some View {
        Label("Audio und Text bleiben auf diesem Gerät.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var legalInformationSheet: some View {
        NavigationStack {
            List {
                Section("Rechtliches") {
                    Link(destination: URL(string: "https://zalozba.de/deutsch/impressum/")!) {
                        Label("Impressum", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://zalozba.de/deutsch/datenschutz/")!) {
                        Label("Datenschutz", systemImage: "hand.raised")
                    }
                }

                Section("Danksagung") {
                    Text("Herzlichen Dank an Bernhard Baier für die Namensidee und das Logo von Sorbfisch.")
                        .padding(.vertical, 4)
                }

                Section("Entwicklung") {
                    Text("Die App wurde im Auftrag der Stiftung für das sorbische Volk von Karl Baier entwickelt.")
                        .padding(.vertical, 4)
                }

                Section {
                    Button(role: .destructive) {
                        guard viewModel.canClearModelStorage, !isConfirmingModelDeletion else { return }
                        modelStorageResultMessage = ""
                        isConfirmingModelDeletion = true
                    } label: {
                        Label("Heruntergeladene Modelle löschen", systemImage: "trash")
                    }
                    .disabled(!viewModel.canClearModelStorage)

                    if viewModel.isClearingModelStorage {
                        ProgressView("Modellspeicher wird gelöscht …")
                    } else if !modelStorageResultMessage.isEmpty {
                        Text(modelStorageResultMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Modellspeicher")
                } footer: {
                    Text("Löscht alle heruntergeladenen Modelle, Tokenizer und unvollständigen Downloads. Beim nächsten Laden ist wieder Internet nötig. Dein Transkript bleibt erhalten. Bitte beende zuerst die Aufnahme und warte, bis das Modell fertig geladen ist.")
                }

            }
            .navigationTitle("Über Sorbfisch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        isShowingLegalInformation = false
                    }
                    .disabled(viewModel.isClearingModelStorage)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.isClearingModelStorage)
        .confirmationDialog(
            "Alle heruntergeladenen Modelle löschen?",
            isPresented: $isConfirmingModelDeletion,
            titleVisibility: .visible
        ) {
            Button("Alle Modelle löschen", role: .destructive) {
                // Close the confirmation before async model-state changes redraw
                // the sheet. Report completion inline, not in a second dialog.
                isConfirmingModelDeletion = false
                guard viewModel.canClearModelStorage else { return }
                Task {
                    do {
                        try await viewModel.clearModelStorage()
                        modelStorageResultMessage = "Der Modellspeicher wurde gelöscht. Beim nächsten Laden wird das ausgewählte Modell erneut heruntergeladen."
                    } catch {
                        modelStorageResultMessage = "Der Modellspeicher konnte nicht vollständig gelöscht werden: \(error.localizedDescription)"
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {
                isConfirmingModelDeletion = false
            }
        } message: {
            Text("Die heruntergeladenen Dateien werden dauerhaft entfernt. Dein Transkript und die mitgelieferten Dateien bleiben erhalten.")
        }
    }

    private var recordingControlAccessibilityLabel: String {
        if viewModel.isRecording { return "Aufnahme stoppen" }
        if viewModel.modelState == .ready { return "Aufnahme starten" }
        if viewModel.modelState == .failed { return "Sprachmodell erneut laden" }
        return "Sprachmodell laden"
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch viewModel.modelState {
        case .idle:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sprachmodell nicht geladen")
        case .loading, .unloading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(viewModel.controlHint)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Sprachmodell bereit")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Sprachmodell nicht verfügbar")
        }
    }
}

/// UTF-8 preserves Upper Sorbian letters such as č, ć, ě, ł, ń, š and ž.
nonisolated private struct TranscriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct WaveformView: View {
    let levels: [Float]
    let isActive: Bool
    private let barCount = 28

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(isActive ? Color.red.opacity(0.82) : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: barHeight(at: index))
            }
        }
        .animation(.easeOut(duration: 0.15), value: levels)
        .accessibilityHidden(true)
    }

    private func barHeight(at index: Int) -> CGFloat {
        guard isActive, !levels.isEmpty else {
            return CGFloat(5 + (index % 4) * 2)
        }

        let levelIndex = min(levels.count - 1, index * levels.count / barCount)
        let normalized = min(max(CGFloat(levels[levelIndex]), 0), 1)
        return max(5, normalized * 40)
    }
}

#Preview {
    ContentView()
}
