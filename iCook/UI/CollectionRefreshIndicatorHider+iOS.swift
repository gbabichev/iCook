#if os(iOS)
import SwiftUI
import UIKit

// Keep SwiftUI's refresh action, gesture and insets; only hide its indicator.
// Attach inside the collection scroll content to avoid styling other screens.
struct CollectionRefreshIndicatorHider: UIViewRepresentable {
    func makeUIView(context: Context) -> IndicatorHiderView {
        let view = IndicatorHiderView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: IndicatorHiderView, context: Context) {
        uiView.updateIndicator()
        // SwiftUI may install the refresh control after this update.
        DispatchQueue.main.async { [weak uiView] in
            uiView?.updateIndicator()
        }
    }

    static func dismantleUIView(_ uiView: IndicatorHiderView, coordinator: ()) {
        uiView.restoreIndicator()
    }

    final class IndicatorHiderView: UIView {
        private weak var refreshControl: UIRefreshControl?
        private var originalTintColor: UIColor?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                restoreIndicator()
            } else {
                updateIndicator()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateIndicator()
        }

        func updateIndicator() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    guard let control = scrollView.refreshControl else { return }
                    if refreshControl !== control {
                        restoreIndicator()
                        refreshControl = control
                        originalTintColor = control.tintColor
                    }
                    control.tintColor = .clear
                    return
                }
                ancestor = view.superview
            }
        }

        func restoreIndicator() {
            refreshControl?.tintColor = originalTintColor
            refreshControl = nil
            originalTintColor = nil
        }
    }
}
#endif
