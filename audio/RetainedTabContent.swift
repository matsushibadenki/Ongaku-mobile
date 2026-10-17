import SwiftUI
import UIKit

/// Content-only tabs for the custom menu. No UITabBar is created, even during
/// the first layout. Each visited page keeps its hosting controller and state.
struct RetainedTabContent<Selection: Hashable, Content: View>: UIViewControllerRepresentable {
    var selection: Selection
    @ViewBuilder var content: (Selection) -> Content

    func makeUIViewController(context: Context) -> Container {
        Container()
    }

    func updateUIViewController(_ controller: Container, context: Context) {
        controller.show(selection, content: AnyView(
            content(selection).environment(\.self, context.environment)
        ))
    }

    final class Container: UIViewController {
        private var pages: [Selection: UIHostingController<AnyView>] = [:]
        private var activeSelection: Selection?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
        }

        func show(_ selection: Selection, content: AnyView) {
            let next: UIHostingController<AnyView>
            if let cached = pages[selection] {
                next = cached
                next.rootView = content
            } else {
                next = UIHostingController(rootView: content)
                // SwiftUI's outer viewport already accounts for safe areas.
                next.safeAreaRegions = []
                next.view.backgroundColor = .clear
                pages[selection] = next
            }
            guard activeSelection != selection else { return }

            let isVisible = isViewLoaded && view.window != nil
            if let activeSelection, let previous = pages[activeSelection] {
                previous.willMove(toParent: nil)
                if isVisible { previous.beginAppearanceTransition(false, animated: false) }
                previous.view.removeFromSuperview()
                previous.removeFromParent()
                if isVisible { previous.endAppearanceTransition() }
            }

            activeSelection = selection
            addChild(next)
            next.view.frame = view.bounds
            next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if isVisible { next.beginAppearanceTransition(true, animated: false) }
            view.addSubview(next.view)
            next.didMove(toParent: self)
            if isVisible { next.endAppearanceTransition() }
        }
    }
}
