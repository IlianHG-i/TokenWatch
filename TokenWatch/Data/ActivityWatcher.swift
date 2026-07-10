import Foundation

/// Surveille `~/.claude/projects` avec FSEvents. Une écriture de fichier
/// (= une consommation réelle de tokens par Claude Code) déclenche un callback
/// *debouncé*, pour ne rafraîchir l'usage que quand il change vraiment — au
/// repos, aucune requête réseau.
final class ActivityWatcher {
    private let path: String
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "com.ilianhg.tokenwatch.fsevents")
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?

    init(path: String, debounce: TimeInterval = 2.5, onChange: @escaping () -> Void) {
        self.path = path
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ActivityWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .scheduleFire()
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latence de coalescence côté système
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private func scheduleFire() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
