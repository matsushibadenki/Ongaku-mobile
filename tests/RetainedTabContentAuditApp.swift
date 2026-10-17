import SwiftUI
import UIKit

// Compile with audio/RetainedTabContent.swift as a standalone simulator app.
@MainActor private enum Audit {
    static var appearances: [Int: [Int]] = [:]
    static var disappearances: [Int: Int] = [:]
    static var paths: [Int: [Int]] = [:]
}

private struct AuditPage: View {
    let index: Int
    @State private var appearances = 0
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            Text("Page \(index)")
                .navigationDestination(for: Int.self) { Text("Detail \($0)") }
        }
        .onAppear {
            appearances += 1
            Audit.appearances[index, default: []].append(appearances)
            if path.isEmpty { path = [index + 100] }
        }
        .onDisappear { Audit.disappearances[index, default: 0] += 1 }
        .onChange(of: path, initial: true) { _, value in Audit.paths[index] = value }
    }
}

@main @MainActor final class AuditApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let container = RetainedTabContent<Int, EmptyView>.Container()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = container
        container.show(0, content: AnyView(AuditPage(index: 0)))
        window.makeKeyAndVisible()
        Task { await run() }
        return true
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    private func run() async {
        await settle()
        let first = container.children.first!
        precondition(Audit.appearances[0] == [1])
        precondition(Audit.paths[0] == [100])
        container.show(1, content: AnyView(AuditPage(index: 1)))
        await settle()
        precondition(container.children.count == 1)
        precondition(Audit.disappearances[0] == 1)
        precondition(Audit.appearances[1] == [1])
        let second = container.children.first!
        container.show(0, content: AnyView(AuditPage(index: 0)))
        await settle()
        precondition(container.children.first === first)
        precondition(Audit.appearances[0] == [1, 2], "SwiftUI state must survive tab changes")
        precondition(Audit.paths[0] == [100], "Navigation path must survive tab changes")
        precondition(Audit.disappearances[1] == 1)
        container.show(0, content: AnyView(AuditPage(index: 0)))
        await settle()
        precondition(Audit.appearances[0] == [1, 2], "Root refresh must not repeat appearance")
        container.show(1, content: AnyView(AuditPage(index: 1)))
        await settle()
        precondition(container.children.first === second)
        precondition(Audit.appearances[1] == [1, 2])
        precondition(Audit.paths[1] == [101])
        func containsTabBar(_ view: UIView) -> Bool {
            view is UITabBar || view.subviews.contains(where: containsTabBar)
        }
        precondition(!containsTabBar(window!), "A content-only container must never create a native tab bar")
        let report = "PASS: retained hosts, local state, navigation paths, appearance/disappearance, refresh, no native tab bar"
        try! report.write(to: URL.documentsDirectory.appendingPathComponent("retained-tab-audit.txt"), atomically: true, encoding: .utf8)
    }
}
