import Foundation

/// Watches the TV app's download folder. A kernel event says a package folder appeared, or a
/// new package inside one; then one bounded poll per folder waits until the package lists its
/// subtitle tracks. Tracks the download did not finish are fetched from their URLs at ingest.
@MainActor
public final class DownloadWatcher {
    public enum LaunchAction: Equatable { case ingest, poll, skip }

    static let pollInterval: DispatchTimeInterval = .seconds(2)
    /// `boot.xml` lists every track within seconds of a Download press.
    nonisolated public static let pollWindow: TimeInterval = 60

    nonisolated public static var defaultDirectory: URL {
        URL.moviesDirectory.appending(path: "TV/Media.localized/Downloads-TV")
    }

    /// The live package of a `.tmp` folder. Each Download press makes a new `download N.movpkg`
    /// in the folder; the newest `boot.xml` marks the current attempt.
    nonisolated public static func newestPackage(in folder: URL) -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let dated = names.filter { $0.hasSuffix(".movpkg") }.compactMap { name -> (URL, Date)? in
            let package = folder.appending(path: name)
            return bootModified(package).map { (package, $0) }
        }
        return dated.max { $0.1 < $1.1 }?.0 ?? folder.appending(path: "download.movpkg")
    }

    nonisolated static func bootModified(_ package: URL) -> Date? {
        (try? package.appending(path: "boot.xml").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// At launch: ingest complete packages, poll recent ones, skip old incomplete ones.
    nonisolated public static func launchAction(complete: Bool, age: TimeInterval) -> LaunchAction {
        if complete { return .ingest }
        return age < pollWindow ? .poll : .skip
    }

    private let directory: URL
    private let onReady: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    /// Finishes once the folder is open and watched.
    private(set) var opening: Task<Void, Never>?
    private var known = Set<String>()
    private var folderSources: [String: DispatchSourceFileSystemObject] = [:]
    private var jobs: [String: DispatchSourceTimer] = [:]
    /// Track folders listed at the last poll, per package folder: the same list twice means
    /// `boot.xml` is settled.
    private var listed: [String: [String]] = [:]

    /// `onReady` gets the package URL once it lists its subtitle tracks, complete or not.
    public init(directory: URL = DownloadWatcher.defaultDirectory, onReady: @escaping (URL) -> Void) {
        self.directory = directory
        self.onReady = onReady
    }

    /// macOS asks for media library access inside the folder's open(), which waits for the
    /// answer; it runs off the main thread so the app stays usable meanwhile.
    public func start() {
        let path = directory.path
        opening = Task { [weak self] in
            let fd = await Task.detached { open(path, O_EVTONLY | O_CLOEXEC) }.value
            guard let self, !Task.isCancelled else {
                if fd >= 0 { close(fd) }
                return
            }
            self.watch(fd)
        }
    }

    private func watch(_ fd: Int32) {
        guard fd >= 0 else {
            Log.ingest.error("download folder not found")
            return
        }
        source = watchSource(fd) { [weak self] in self?.folderChanged() }
        for folder in packageFolders() {
            known.insert(folder)
            watchFolder(folder)
            let pkg = package(folder)
            let complete = (try? MoviePackageReader.manifest(package: pkg))?.allComplete ?? false
            let modified = Self.bootModified(pkg) ?? .distantPast
            switch Self.launchAction(complete: complete, age: Date().timeIntervalSince(modified)) {
            case .ingest: onReady(pkg)
            case .poll: startPolling(folder)
            case .skip: continue
            }
        }
    }

    public func stop() {
        opening?.cancel()
        opening = nil
        source?.cancel()
        source = nil
        folderSources.values.forEach { $0.cancel() }
        folderSources = [:]
        jobs.values.forEach { $0.cancel() }
        jobs = [:]
    }

    private func watchSource(_ fd: Int32, _ handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// A new package inside a known folder (a second Download press) restarts its poll; the
    /// folder's own event is the only sign of it.
    private func watchFolder(_ folder: String) {
        guard folderSources[folder] == nil else { return }
        let fd = open(directory.appending(path: folder).path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        folderSources[folder] = watchSource(fd) { [weak self] in self?.startPolling(folder) }
    }

    private func folderChanged() {
        let folders = Set(packageFolders())
        for folder in known.subtracting(folders) {
            folderSources[folder]?.cancel()
            folderSources[folder] = nil
            jobs[folder]?.cancel()
            jobs[folder] = nil
        }
        for folder in folders.subtracting(known) {
            watchFolder(folder)
            startPolling(folder)
        }
        known = folders
    }

    private func startPolling(_ folder: String) {
        guard jobs[folder] == nil else { return }
        let deadline = Date().addingTimeInterval(Self.pollWindow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll(folder, deadline: deadline) }
        }
        timer.resume()
        jobs[folder] = timer
    }

    /// Ready when every track is complete, or when the track list is the same as at the last
    /// poll: `boot.xml` grows for a moment after the press, then only completion marks change.
    private func poll(_ folder: String, deadline: Date) {
        let pkg = package(folder)
        let finish = { [weak self] in
            self?.jobs[folder]?.cancel()
            self?.jobs[folder] = nil
            self?.listed[folder] = nil
        }
        guard FileManager.default.fileExists(atPath: pkg.deletingLastPathComponent().path) else { return finish() }
        if let manifest = try? MoviePackageReader.manifest(package: pkg), !manifest.tracks.isEmpty {
            let paths = manifest.tracks.map(\.path)
            if manifest.allComplete || paths == listed[folder] {
                finish()
                onReady(pkg)
                return
            }
            listed[folder] = paths
        }
        if Date() > deadline { finish() }
    }

    private func packageFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }

    private func package(_ folder: String) -> URL {
        Self.newestPackage(in: directory.appending(path: folder))
    }
}
