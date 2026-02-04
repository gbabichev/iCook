import SwiftUI

struct TutorialView: View {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let systemImage: String
    }
    
    private let steps: [Step] = [
        Step(
            title: "Collections",
            message: "Collections are your top-level spaces. Keep separate groups for personal, family, or projects.",
            systemImage: "books.vertical"
        ),
        Step(
            title: "Categories",
            message: "Categories organize recipes inside a collection. Think Breakfast, Dinner, or Desserts.",
            systemImage: "tag"
        ),
        Step(
            title: "Recipes",
            message: "Recipes hold the details: time, notes, steps, and images. Add as many as you like.",
            systemImage: "book"
        ),
        Step(
            title: "Sharing Collections",
            message: "Share a collection to collaborate. Everyone sees updates and can add recipes together.",
            systemImage: "person.2"
        )
    ]
    
    @State private var index = 0
    let onDone: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            TutorialStepView(step: steps[index])
                .padding(.horizontal, 24)
                .frame(maxWidth: 520, maxHeight: 340)
                .id(index)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .animation(.easeInOut(duration: 0.2), value: index)
            
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { idx in
                    Circle()
                        .fill(idx == index ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: idx == index ? 10 : 8, height: idx == index ? 10 : 8)
                        .animation(.easeInOut(duration: 0.15), value: index)
                }
            }
            
            HStack(spacing: 12) {
                Button("Skip") { onDone() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Back") {
                    if index > 0 { index -= 1 }
                }
                .buttonStyle(.bordered)
                .disabled(index == 0)
                
                Button(index == steps.count - 1 ? "Done" : "Next") {
                    if index == steps.count - 1 {
                        onDone()
                    } else {
                        index += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 520)
            
            Spacer()
        }
        .padding(24)
    }
}

private struct TutorialStepView: View {
    let step: TutorialView.Step
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: step.systemImage)
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(.accentColor)
            
            Text(step.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            
            Text(step.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
