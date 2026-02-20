//
//  ModifyTag.swift
//  iCook
//
//  Created by Codex on 2/15/26.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct AddTagView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let editingTag: Tag?

    @State private var tagName = ""
    @State private var isSaving = false
    @State private var isDeleting = false

    var isEditing: Bool { editingTag != nil }

    init(editingTag: Tag? = nil) {
        self.editingTag = editingTag
    }

    private var trimmedTagName: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDuplicateName: Bool {
        model.tags.contains {
            if let editingTag, $0.id == editingTag.id { return false }
            return $0.name.compare(trimmedTagName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var showDuplicateWarning: Bool {
        hasDuplicateName && !isSaving && !isDeleting
    }

    private var canEdit: Bool {
        guard let source = model.currentSource else { return false }
        return model.canEditSource(source)
    }

    private var saveButtonDisabled: Bool {
        !canEdit || trimmedTagName.isEmpty || hasDuplicateName || isSaving
    }

    var body: some View {
        Group {
#if os(macOS)
            macOSView
#else
            iOSView
#endif
        }
        .task {
            if let tag = editingTag {
                tagName = tag.name
            }
        }
        .alert("Error",
               isPresented: .init(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
               ),
               actions: { Button("OK") { model.error = nil } },
               message: { Text(model.error ?? "") }
        )
    }

    private var iOSView: some View {
        NavigationStack {
            Form {
                if model.currentSource == nil {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Please create a collection first.")
                                .foregroundColor(.red)
                        }
                    }
                } else if let source = model.currentSource, !model.canEditSource(source) {
                    Section {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundColor(.orange)
                            Text("This collection is read-only")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section("Tag Information") {
                    TextField("Tag Name", text: $tagName)
                        .iOSModernInputFieldStyle()
#if os(iOS)
                        .textInputAutocapitalization(.words)
#endif
                        .disabled(!canEdit)
                }

                Section {
                    Text("Label recipes with flexible keywords")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showDuplicateWarning {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A tag with this name already exists.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Task {
                                await deleteTag()
                            }
                        } label: {
                            if isDeleting {
                                HStack {
                                    ProgressView()
                                    Text("Deleting...")
                                }
                            } else {
                                Text("Delete Tag")
                            }
                        }
                        .disabled(!canEdit || isSaving || isDeleting)
                    }
                }
            }
            .formStyle(.grouped)
#if os(iOS)
            .scrollDismissesKeyboard(.immediately)
#endif
            .navigationTitle(isEditing ? "Edit Tag" : "Add Tag")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Update" : "Create") {
                        Task {
                            await saveTag()
                        }
                    }
                    .disabled(saveButtonDisabled)
                }
#if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
#endif
            }
        }
    }

#if os(macOS)
    private var macOSView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "Edit Tag" : "Add Tag")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Label recipes with flexible keywords")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isEditing ? "Update" : "Create") {
                    Task {
                        await saveTag()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveButtonDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusBanner

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tag Information")
                            .font(.headline)

                        TextField("Tag Name", text: $tagName)
                            .iOSModernInputFieldStyle()
                            .disabled(!canEdit)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if showDuplicateWarning {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("A tag with this name already exists.")
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if isEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Danger Zone")
                                .font(.headline)

                            Button(role: .destructive) {
                                Task {
                                    await deleteTag()
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isDeleting {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Deleting...")
                                    } else {
                                        Text("Delete Tag")
                                            .fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(!canEdit || isSaving || isDeleting)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var statusBanner: some View {
        if model.currentSource == nil {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text("Create a collection first before adding tags.")
                    .font(.callout)
            }
            .padding(12)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        } else if let source = model.currentSource, !model.canEditSource(source) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.orange)
                Text("This collection is read-only.")
                    .font(.callout)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
#endif

    @MainActor
    private func saveTag() async {
        isSaving = true

        guard !trimmedTagName.isEmpty, !hasDuplicateName else {
            isSaving = false
            return
        }

        let success: Bool
        if let tag = editingTag {
            success = await model.updateTag(id: tag.id, name: trimmedTagName)
        } else {
            success = await model.createTag(name: trimmedTagName)
        }

        if success {
            dismiss()
            return
        }

        isSaving = false
    }

    @MainActor
    private func deleteTag() async {
        guard let tag = editingTag else { return }
        isDeleting = true

        let success = await model.deleteTag(id: tag.id)
        if success {
            dismiss()
            return
        }

        isDeleting = false
    }

#if os(iOS)
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif
}
