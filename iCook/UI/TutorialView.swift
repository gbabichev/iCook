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
            systemImage: "book"
        ),
        Step(
            title: "Categories",
            message: "Categories organize recipes inside a collection. Think Breakfast, Dinner, or Desserts.",
            systemImage: "tray"
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
        ),
        Step(
            title: "Copy to Reminders",
            message: "Press the 'Copy' button next to Ingredients to copy items to paste directly into the Reminders app.",
            systemImage: "doc.on.clipboard"
        )
    ]
    
    @State private var index = 0
    let onDone: () -> Void
    
    var body: some View {
#if os(iOS)
        iOSTutorialView
#else
        macOSTutorialView
#endif
    }

#if os(iOS)
    private var iOSTutorialView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.systemBackground),
                    Color(.systemGray6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button("Skip") {
                        onDone()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $index) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        iOSStepCard(step: step)
                            .padding(.horizontal, 20)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.2), value: index)

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(steps.indices, id: \.self) { idx in
                            Capsule()
                                .fill(idx == index ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: idx == index ? 22 : 8, height: 8)
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: index)

                    Text("Step \(index + 1) of \(steps.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button(index == steps.count - 1 ? "Get Started" : "Continue") {
                    if index == steps.count - 1 {
                        onDone()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            index += 1
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
    }
#endif

    private var macOSTutorialView: some View {
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

#if os(iOS)
private struct iOSStepCard: View {
    let step: TutorialView.Step

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 110, height: 110)
                Image(systemName: step.systemImage)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 14)

            Text(step.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(step.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
#endif

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
