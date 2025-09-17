import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var editingRecipe: Recipe?
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: recipe.imageURL) { phase in
                    switch phase {
                    case .empty:
                        ZStack {
                            Rectangle().opacity(0.08)
                            ProgressView()
                        }
                        .frame(height: 250)
                        .backgroundExtensionEffect()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 250)
                            .clipped()
                            .backgroundExtensionEffect()
                    case .failure:
                        ZStack {
                            Rectangle().opacity(0.08)
                            Image(systemName: "photo")
                        }
                        .frame(height: 250)
                        .backgroundExtensionEffect()
                    @unknown default:
                        EmptyView()
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text(recipe.name)
                        .font(.largeTitle)
                        .bold()
                    
                    Text("\(recipe.recipe_time) minutes")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    if let details = recipe.details, !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                            .padding(.vertical, 8)
                        
                        Text("Instructions")
                            .font(.title2)
                            .bold()
                            .padding(.bottom, 4)
                        
                        Text(details)
                            .font(.body)
                            .lineSpacing(4)
                    } else {
                        Text("No recipe details available.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .navigationTitle(recipe.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingRecipe = recipe
                    } label: {
                        Label("Edit Recipe", systemImage: "pencil")
                    }
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Recipe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editingRecipe) { recipe in
            AddEditRecipeView(editingRecipe: recipe)
                .environmentObject(model)
        }
        .alert("Delete Recipe", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRecipe()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete '\(recipe.name)'? This action cannot be undone.")
        }
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Deleting recipe...")
                            .font(.headline)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    @MainActor
    private func deleteRecipe() async {
        isDeleting = true
        let success = await model.deleteRecipeWithUIFeedback(id: recipe.id)
        isDeleting = false
        
        if success {
            dismiss()
        }
    }
}


extension Notification.Name {
    static let recipeDeleted = Notification.Name("recipeDeleted")
    static let recipeUpdated = Notification.Name("recipeUpdated") // Add this line
}
