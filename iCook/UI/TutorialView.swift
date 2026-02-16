import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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
        redesignedTutorialView
    }

    private var redesignedTutorialView: some View {
        ZStack {
            backgroundGradient
            .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Text("Welcome to iCook")
                        .font(.headline)
                    Spacer()
                    Button("Skip") {
                        onDone()
                    }
                    .buttonStyle(.bordered)
#if os(macOS)
                    .keyboardShortcut(.cancelAction)
#endif
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                TabView(selection: $index) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        TutorialStepCard(step: step)
                            .padding(.horizontal, 20)
#if os(macOS)
                            .tabItem { Text(step.title) }
#endif
                            .tag(idx)
                    }
                }
                .modifier(TutorialPagingStyle())
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
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
#if os(macOS)
                .keyboardShortcut(.defaultAction)
#endif
            }
        }
#if os(macOS)
        .frame(minWidth: 700, minHeight: 520)
#endif
    }

    private var backgroundGradient: LinearGradient {
#if os(iOS)
        return LinearGradient(
            colors: [Color(UIColor.systemBackground), Color(UIColor.secondarySystemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
#else
        return LinearGradient(
            colors: [Color(NSColor.windowBackgroundColor), Color(NSColor.controlBackgroundColor)],
            startPoint: .top,
            endPoint: .bottom
        )
#endif
    }

    private func advance() {
        if index == steps.count - 1 {
            onDone()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            index += 1
        }
    }
}

private struct TutorialPagingStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if os(iOS)
        content.tabViewStyle(.page(indexDisplayMode: .never))
#else
        content
#endif
    }
}

private struct TutorialStepCard: View {
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
                .fill(.regularMaterial)
        )
    }
}
