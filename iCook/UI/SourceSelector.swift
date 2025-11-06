import SwiftUI
import CloudKit

struct SourceSelector: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showNewSourceSheet = false
    @State private var newSourceName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Current source display
            if let source = viewModel.currentSource {
                VStack(spacing: 8) {
                    Text("Current Source")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        ForEach(viewModel.sources, id: \.id) { source in
                            Button {
                                Task {
                                    await viewModel.selectSource(source)
                                }
                            } label: {
                                HStack {
                                    Text(source.name)
                                    if viewModel.currentSource?.id == source.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: { showNewSourceSheet = true }) {
                            Label("New Personal Source", systemImage: "plus")
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                    .font(.headline)
                                Text(source.isPersonal ? "Personal" : "Shared")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }

            Divider()

            // Sources List
            if viewModel.sources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)

                    Text("No Sources")
                        .font(.headline)

                    Text("Create a new personal source to get started")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { showNewSourceSheet = true }) {
                        Label("New Source", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                List {
                    Section(header: Text("My Sources")) {
                        ForEach(viewModel.sources.filter { $0.isPersonal }, id: \.id) { source in
                            SourceRow(
                                source: source,
                                isSelected: viewModel.currentSource?.id == source.id,
                                onSelect: {
                                    Task {
                                        await viewModel.selectSource(source)
                                    }
                                },
                                onDelete: {
                                    Task {
                                        _ = await viewModel.deleteSource(source)
                                    }
                                }
                            )
                        }
                    }

                    if !viewModel.sources.filter({ !$0.isPersonal }).isEmpty {
                        Section(header: Text("Shared Sources")) {
                            ForEach(viewModel.sources.filter { !$0.isPersonal }, id: \.id) { source in
                                SourceRow(
                                    source: source,
                                    isSelected: viewModel.currentSource?.id == source.id,
                                    onSelect: {
                                        Task {
                                            await viewModel.selectSource(source)
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            _ = await viewModel.deleteSource(source)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            // New source button
            Button(action: { showNewSourceSheet = true }) {
                Label("New Source", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding()
        }
        .sheet(isPresented: $showNewSourceSheet) {
            NewSourceSheet(
                isPresented: $showNewSourceSheet,
                viewModel: viewModel,
                sourceName: $newSourceName
            )
        }
    }
}

struct SourceRow: View {
    let source: Source
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.headline)
                    .fontWeight(isSelected ? .semibold : .regular)

                Text(source.isPersonal ? "Personal" : "Shared")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
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
    @ObservedObject var viewModel: AppViewModel
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
    SourceSelector(viewModel: AppViewModel())
}
