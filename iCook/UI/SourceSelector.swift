import SwiftUI
import CloudKit

struct SourceSelector: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""
    @State private var showShareSheet = false
    @State private var sourceToShare: Source?
    @State private var pendingShare: CKShare?
    @State private var pendingRecord: CKRecord?
    @State private var isPreparingShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)

                        Text("No Sources")
                            .font(.headline)

                        Text("Create a new source to get started")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.gray.opacity(0.05))
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(viewModel.sources, id: \.id) { source in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(source.name)
                                            .font(.headline)
                                            .fontWeight(viewModel.currentSource?.id == source.id ? .semibold : .regular)

                                        Text(source.isPersonal ? "Personal" : "Shared")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    // Share button for personal sources
                                    if source.isPersonal {
                                        Button(action: {
                                            Task {
                                                await prepareShare(for: source)
                                            }
                                        }) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.system(size: 16))
                                                .foregroundColor(.blue)
                                                .padding(8)
                                        }
                                    }

                                    // Selection indicator
                                    if viewModel.currentSource?.id == source.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task {
                                        await viewModel.selectSource(source)
                                    }
                                }
                                .padding()
                                .background(.gray.opacity(0.05))
                                .cornerRadius(8)
                            }
                            .padding()
                        }
                    }
                }

                Divider()

                // New source button
                Button(action: { showNewSourceSheet = true }) {
                    Label("New Source", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .navigationTitle("Sources")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task {
                // Refresh sources when overlay opens
                await viewModel.loadSources()
            }
        }
        .sheet(isPresented: $showNewSourceSheet) {
            NewSourceSheet(
                isPresented: $showNewSourceSheet,
                sourceName: $newSourceName
            )
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showShareSheet) {
            if let share = pendingShare, let record = pendingRecord {
                CloudSharingSheet(
                    isPresented: $showShareSheet,
                    container: viewModel.cloudKitManager.container,
                    share: share,
                    record: record,
                    content: { EmptyView() },
                    onCompletion: { success in
                        if success {
                            Task {
                                _ = await viewModel.cloudKitManager.saveShare(share, for: record)
                            }
                        }
                    }
                )
            }
        }
    }

    private func prepareShare(for source: Source) async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        if let (share, record) = await viewModel.cloudKitManager.prepareShareForSource(source) {
            pendingShare = share
            pendingRecord = record
            sourceToShare = source
            showShareSheet = true
        }
    }
}

struct SourceRow: View {
    let source: Source
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Source info
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.headline)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(source.isPersonal ? "Personal" : "Shared")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Share button for personal sources
            if source.isPersonal {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                        .padding(8)
                }
            }

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Delete Source", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text("Are you sure you want to delete '\(source.name)'? This will also delete all recipes in this source.")
        }
    }
}

struct NewSourceSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: AppViewModel
    @Binding var sourceName: String
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Source Name") {
                    TextField("e.g., Family Recipes", text: $sourceName)
                }

                Section {
                    Text("Personal sources are stored in your private iCloud space and can be shared with others.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("New Source")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                        sourceName = ""
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        isCreating = true
                        Task {
                            _ = await viewModel.createSource(name: sourceName)
                            isPresented = false
                            sourceName = ""
                            isCreating = false
                        }
                    }
                    .disabled(sourceName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
    }
}

#Preview {
    SourceSelector()
        .environmentObject(AppViewModel())
}
