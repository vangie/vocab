import AppKit
import Combine
import VocabCore

/// One place in the app the global ‹ › history can return to.
enum AppScreen: Equatable {
    case lookup(String)
    /// 记词: a list (with its filter) or 今日 (rings / the quiz in progress; ReviewSession is shared,
    /// so coming back shows the same question in the same state).
    case words(WordGroup, WordbookScope, String)
}

/// Global back/forward over app screens (toolbar ‹ ›, ⌘[ / ⌘], swipe).
@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published private(set) var stack = NavStack<AppScreen>()
    private var bag: Set<AnyCancellable> = []
    private var restoring: AppScreen?
    private var swipeMonitor: Any?

    var canGoBack: Bool { stack.canGoBack }
    var canGoForward: Bool { stack.canGoForward }

    func start() {
        guard bag.isEmpty else { return }
        let s = AppState.shared, l = LookupModel.shared
        Publishers.CombineLatest4(s.$mode, s.$wordGroup, s.$wordScope, s.$wordFilter)
            .combineLatest(l.$searchedTerm)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] v, term in
                let (mode, group, scope, filter) = v
                self?.observe(mode == .lookup ? .lookup(term) : .words(group, scope, filter))
            }.store(in: &bag)
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] e in
            guard let self, e.window?.toolbar?.identifier == "vocab.main" else { return e }
            if e.deltaX > 0 { self.back(); return nil }
            if e.deltaX < 0 { self.forward(); return nil }
            return e
        }
    }

    private func observe(_ s: AppScreen) {
        if case .lookup(let w) = s, w.isEmpty { return }
        if let r = restoring { if r == s { restoring = nil }; return }
        if case .words(let g, let sc, _) = s, case .words(let g0, let sc0, _)? = stack.current, g == g0, sc == sc0 {
            stack.replaceCurrent(s); return   // typing in the 记词 filter refines the same entry
        }
        stack.visit(s)
    }

    func back() { if let s = stack.back() { apply(s) } }
    func forward() { if let s = stack.forward() { apply(s) } }

    private func apply(_ s: AppScreen) {
        restoring = s
        let st = AppState.shared
        switch s {
        case .lookup(let w):
            st.mode = .lookup
            if LookupModel.shared.searchedTerm != w { LookupModel.shared.open(w, record: false) }
        case .words(let g, let sc, let f):
            st.wordGroup = g; st.wordScope = sc; st.wordFilter = f
            st.mode = .words
        }
        // If nothing observable changed (already there), don't swallow the next real visit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in if self?.restoring == s { self?.restoring = nil } }
    }
}
