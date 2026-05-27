import AppKit
import DonkeyAI
import DonkeyRuntime
import SwiftUI

@MainActor
final class DocumentFormFillReviewWindowController {
    private var window: NSWindow?
    private var viewModel: DocumentFormFillReviewViewModel?

    func show(request: DocumentFormFillReviewRequest) {
        let viewModel = DocumentFormFillReviewViewModel(
            request: request,
            close: { [weak self] in self?.close() }
        )
        self.viewModel = viewModel

        let hostingView = NSHostingView(
            rootView: DocumentFormFillReviewView(viewModel: viewModel)
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review Form Fill"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func close() {
        window?.close()
        window = nil
        viewModel = nil
    }
}

@MainActor
private final class DocumentFormFillReviewViewModel: ObservableObject {
    @Published var selectedFieldIDs: Set<String>
    @Published private(set) var statusText: String
    @Published private(set) var isExecuting = false

    let request: DocumentFormFillReviewRequest
    private let close: @MainActor () -> Void
    private let runner: DocumentFormFillApprovalLiveRunner

    init(
        request: DocumentFormFillReviewRequest,
        close: @escaping @MainActor () -> Void,
        runner: DocumentFormFillApprovalLiveRunner = DocumentFormFillApprovalLiveRunner(
            appController: MacLocalAppTaskController(
                uiUnderstandingRunner: DonkeyUIUnderstandingRunnerFactory.defaultRunner()
            ),
            coordinator: RunCoordinator()
        )
    ) {
        self.request = request
        self.close = close
        self.runner = runner
        selectedFieldIDs = Set(request.plan.proposals.map(\.fieldID))
        statusText = "\(request.plan.proposals.count) proposed fields"
    }

    func approveSelected() {
        guard !isExecuting else { return }

        let fieldIDs = Array(selectedFieldIDs)
        isExecuting = true
        statusText = "Applying approved fields..."
        close()

        Task { [request, runner] in
            _ = await runner.run(
                plan: request.plan,
                definition: request.definition,
                traceID: request.traceID,
                approvedFieldIDs: fieldIDs
            )
        }
    }

    func cancel() {
        close()
    }
}

private struct DocumentFormFillReviewView: View {
    @ObservedObject var viewModel: DocumentFormFillReviewViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            proposalList
            footer
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review field values")
                .font(.title3.weight(.semibold))
            Text(viewModel.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var proposalList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.request.plan.proposals, id: \.fieldID) { proposal in
                    Toggle(isOn: selectionBinding(for: proposal.fieldID)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proposal.fieldLabel)
                                .font(.system(size: 13, weight: .semibold))
                            Text(proposal.proposedValue)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Text("From \(proposal.sourceKey)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if !viewModel.request.plan.unmappedRequiredFieldIDs.isEmpty {
                Text("\(viewModel.request.plan.unmappedRequiredFieldIDs.count) required fields are unmapped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                viewModel.cancel()
            }

            Button("Apply Approved") {
                viewModel.approveSelected()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.selectedFieldIDs.isEmpty || viewModel.isExecuting)
        }
    }

    private func selectionBinding(for fieldID: String) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.selectedFieldIDs.contains(fieldID)
            },
            set: { isSelected in
                if isSelected {
                    viewModel.selectedFieldIDs.insert(fieldID)
                } else {
                    viewModel.selectedFieldIDs.remove(fieldID)
                }
            }
        )
    }
}
