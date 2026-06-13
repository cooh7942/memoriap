import Foundation
import AppKit
import AVFoundation
import Combine
import CoreLocation
import ImageIO
import os

struct PhotoItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumbnail: NSImage?
    var coordinate: CLLocationCoordinate2D?
    var rating: Int = 0
    var isVideo: Bool { ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) }
    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.thumbnail === rhs.thumbnail
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
            && lhs.rating == rhs.rating
    }
}

enum ClipboardMode {
    case copy
    case cut
}

struct PendingDropOperation: Equatable {
    let sources: [URL]
    let destination: URL
}

@MainActor
class PhotoBrowserModel: ObservableObject {
    @Published var currentFolderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var selectedIndex: Int? = nil
    @Published var isLoadingFiles = false
    @Published var isLoadingMetadata = false
    @Published var loadProgress: (done: Int, total: Int) = (0, 0)
    @Published var pendingDeletePhoto: PhotoItem? = nil
    @Published var deleteDialogFocus: DeleteConfirmChoice = .trash
    @Published var clipboardURLs: [URL] = []
    @Published var clipboardMode: ClipboardMode = .copy
    @Published var pendingDropOperation: PendingDropOperation? = nil
    @Published var dropDialogFocus: ClipboardMode = .cut
    @Published var lastError: String? = nil
    @Published var ratingFilter: Set<Int> = []
    @Published var currentFolderBecameUnavailable = false
    @Published var isFullScreen: Bool = false
    @Published var selectedIDs: Set<UUID> = []
    @Published var showCorruptedWarning = false
    @Published var corruptedFileNames: [String] = []
    var selectionAnchor: Int? = nil

    // MARK: - Multi-select helpers

    /// 실제 작업(복사/이동/삭제) 대상 URL 목록
    var selectedURLs: [URL] {
        if selectedIDs.isEmpty {
            return selectedPhoto.map { [$0.url] } ?? []
        }
        return photos.filter { selectedIDs.contains($0.id) }.map { $0.url }
    }

    /// 일반 클릭: 단일 선택
    func click(at index: Int) {
        guard photos.indices.contains(index) else { return }
        selectedIndex = index
        selectedIDs = [photos[index].id]
        selectionAnchor = index
    }

    /// ⌘+클릭: 개별 토글
    func toggleSelect(at index: Int) {
        guard photos.indices.contains(index) else { return }
        let id = photos[index].id
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIndex == index {
                if let firstID = selectedIDs.first,
                   let idx = photos.firstIndex(where: { $0.id == firstID }) {
                    selectedIndex = idx
                }
            }
        } else {
            selectedIDs.insert(id)
            selectedIndex = index
        }
        selectionAnchor = index
    }

    /// Shift+클릭: anchor~index 범위 선택
    func rangeSelect(to index: Int) {
        guard photos.indices.contains(index) else { return }
        let anchor = selectionAnchor ?? selectedIndex ?? index
        let lo = min(anchor, index), hi = max(anchor, index)
        selectedIDs = Set(photos[lo...hi].map { $0.id })
        selectedIndex = index
    }

    func enterFullScreen() {
        pendingDeletePhoto = nil
        pendingDropOperation = nil
        isFullScreen = true
    }

    // 사용자가 사이드바에서 우클릭 → "즐겨찾기에 추가"로 등록한 폴더 목록.
    // 루트 접근권이 살아 있는 동안 하위 경로는 자유롭게 접근 가능하므로 경로(String)로 저장한다.
    @Published var customFavorites: [URL] = []
    private let customFavoritesKey = "customFavoritePaths"

    // Sidebar tree nodes subscribe to this to refresh children
    let folderChanged = PassthroughSubject<URL, Never>()

    var selectedPhoto: PhotoItem? {
        guard let idx = selectedIndex, photos.indices.contains(idx) else { return nil }
        return photos[idx]
    }

    var photosWithCoordinates: [PhotoItem] {
        photos.filter { $0.coordinate != nil }
    }

    var visiblePhotos: [PhotoItem] {
        ratingFilter.isEmpty ? photos : photos.filter { ratingFilter.contains($0.rating) }
    }

    func toggleRatingFilter(_ value: Int) {
        if ratingFilter.contains(value) { ratingFilter.remove(value) }
        else { ratingFilter.insert(value) }
    }

    func setRating(_ value: Int, for photo: PhotoItem) {
        let clamped = max(0, min(5, value))
        guard let idx = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos[idx].rating = clamped
        let url = photos[idx].url
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try RatingStore.writeRating(clamped, to: url)
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "별점 저장 실패: \(error.localizedDescription)"
                }
            }
        }
    }

    func applyRatingFilter() {
        guard !ratingFilter.isEmpty else { return }
        let visible = visiblePhotos
        if let selected = selectedPhoto, visible.contains(where: { $0.id == selected.id }) { return }
        if let first = visible.first, let idx = photos.firstIndex(where: { $0.id == first.id }) {
            selectedIndex = idx
        } else {
            selectedIndex = nil
        }
    }

    private let lastFolderPathKey = "lastFolderPath"
    private var metadataTask: Task<Void, Never>?

    init() {
        restoreCustomFavorites()
    }

    // MARK: - Custom favorites (경로 기반 영구 저장)

    /// 사이드바 트리에서 우클릭 → "즐겨찾기에 추가" 시 호출.
    func addCustomFavorite(url: URL) {
        if customFavorites.contains(url) {
            lastError = "이미 추가된 폴더입니다: \(url.lastPathComponent)"
            return
        }
        customFavorites.append(url)
        persistCustomFavorites()
    }

    /// 즐겨찾기에서 제거
    func removeCustomFavorite(_ url: URL) {
        guard let idx = customFavorites.firstIndex(of: url) else { return }
        customFavorites.remove(at: idx)
        persistCustomFavorites()
    }

    private func persistCustomFavorites() {
        UserDefaults.standard.set(customFavorites.map { $0.path }, forKey: customFavoritesKey)
    }

    private func restoreCustomFavorites() {
        guard let paths = UserDefaults.standard.array(forKey: customFavoritesKey) as? [String] else { return }
        let fm = FileManager.default
        customFavorites = paths.compactMap { path -> URL? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    // MARK: - Session restoration (Security-Scoped Bookmark 기반)

    /// 앱 시작 시 ContentView.task에서 한 번 호출.
    /// RootFolderStore가 북마크를 복원하고, 마지막으로 보던 폴더를 로드한다.
    func restoreSession() async {
        let hasValid = RootFolderStore.shared.bootstrapOnLaunch()
        if hasValid, let path = UserDefaults.standard.string(forKey: lastFolderPathKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                let url = URL(fileURLWithPath: path)
                currentFolderURL = url
                await loadPhotos(from: url)
            }
        }
        // hasValid == false 이거나 마지막 폴더가 없으면 ContentView가 폴더 선택 화면을 표시
    }

    private func saveLastFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: lastFolderPathKey)
    }

    // MARK: - Folder loading

    func loadFolder(url: URL) async {
        // Cancel in-flight metadata work
        metadataTask?.cancel()
        metadataTask = nil

        // 폴더가 정말 존재하는지 / 디렉터리가 맞는지 사전 확인.
        // 사용자가 USB가 빠진 사이에 즐겨찾기·트리에서 그 폴더를 클릭하는 경우 등에 안전.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            Logger.app.error("loadFolder: folder unavailable — \(url.path, privacy: .public)")
            lastError = "폴더를 열 수 없습니다: \(url.lastPathComponent)\n(이동·삭제되었거나 외부 디스크가 분리되었을 수 있습니다)"
            if UserDefaults.standard.string(forKey: lastFolderPathKey) == url.path {
                UserDefaults.standard.removeObject(forKey: lastFolderPathKey)
            }
            return
        }

        currentFolderURL = url
        saveLastFolder(url)
        await loadPhotos(from: url)
    }

    private func loadPhotos(from folderURL: URL) async {
        isLoadingFiles = true
        isLoadingMetadata = false
        loadProgress = (0, 0)
        // ⚠️ photos/selectedIndex를 여기서 비우지 않는다.
        // 비웠다가 await 끝난 뒤 다시 채우면 화면이 "비었다가 다시 그려지는" 느낌이 강하다.
        // 새 목록이 준비되면 한 번에(atomic) 교체한다.

        let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v"]

        let (photoURLs, corruptedNames): ([URL], [String]) = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )) ?? []
            let allURLs = contents
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var validURLs: [URL] = []
            var corrupted: [String] = []
            for url in allURLs {
                if PhotoMetadata.isReadablePhoto(url) {
                    validURLs.append(url)
                } else {
                    corrupted.append(url.lastPathComponent)
                }
            }
            return (validURLs, corrupted)
        }.value

        // await 중에 사용자가 다른 폴더로 이동했으면 stale 결과를 적용하지 않음
        guard currentFolderURL == folderURL else { return }

        // 썸네일 캐시 prepopulate — 폴더 재방문이면 즉시 가득 찬 상태로 표시되어
        // "회색 placeholder가 하나씩 채워지는" 리프레쉬 느낌이 없어진다.
        photos = photoURLs.map { url -> PhotoItem in
            var item = PhotoItem(url: url)
            item.thumbnail = thumbnailCache.object(forKey: url as NSURL)
            return item
        }
        selectedIndex = photos.isEmpty ? nil : 0
        selectedIDs = photos.isEmpty ? [] : [photos[0].id]
        selectionAnchor = photos.isEmpty ? nil : 0
        isLoadingFiles = false

        if !corruptedNames.isEmpty {
            corruptedFileNames = corruptedNames
            showCorruptedWarning = true
        }

        guard !photoURLs.isEmpty else { return }

        // Parallel metadata loading (High #5)
        isLoadingMetadata = true
        loadProgress = (0, photoURLs.count)

        let urls = photoURLs
        // ⚠️ 우선순위 .utility는 "결과를 기다리지 않는 백그라운드 작업"용 — 시스템이 다른 일이 있으면 throttling.
        // 사용자가 그 썸네일을 지금 보고 있으므로 .userInitiated가 맞다.
        metadataTask = Task.detached(priority: .userInitiated) { [weak self] in
            let maxConcurrent = 3   // 동시 생성 상한 (동영상 포화 방지)
            await withTaskGroup(of: (Int, NSImage?, CLLocationCoordinate2D?, Int).self) { group in
                var next = 0
                let count = urls.count

                // 초기 maxConcurrent 개 투입
                while next < min(maxConcurrent, count) {
                    let i = next; next += 1
                    let url = urls[i]
                    group.addTask {
                        guard !Task.isCancelled else { return (i, nil, nil, 0) }
                        let ext = url.pathExtension.lowercased()
                        let isVideo = ["mov", "mp4", "m4v"].contains(ext)
                        let thumb = isVideo
                            ? await PhotoMetadata.loadVideoThumbnail(from: url)
                            : PhotoMetadata.loadThumbnail(from: url)
                        let coord = isVideo ? nil : PhotoMetadata.extractGPS(from: url)
                        let rating = isVideo ? 0 : RatingStore.readRating(from: url)
                        return (i, thumb, coord, rating)
                    }
                }

                // ⚠️ 결과를 즉시 적용하지 않고 batchSize만큼 모았다가 한 번에 MainActor에서 처리.
                // 1000장 폴더에서 MainActor hop 1000번 → 50번으로 줄어 SwiftUI 재평가 부담이 크게 감소.
                let batchSize = 20
                var pending: [(Int, NSImage?, CLLocationCoordinate2D?, Int)] = []
                pending.reserveCapacity(batchSize)
                var done = 0

                func flush(_ totalDone: Int) async {
                    guard !pending.isEmpty else { return }
                    let batch = pending
                    pending.removeAll(keepingCapacity: true)
                    await MainActor.run { [weak self] in
                        guard let self, self.currentFolderURL == folderURL else { return }
                        for (i, thumb, coord, rating) in batch {
                            guard i < self.photos.count,
                                  self.photos[i].url == urls[i] else { continue }
                            self.photos[i].thumbnail = thumb
                            self.photos[i].coordinate = coord
                            self.photos[i].rating = rating
                        }
                        self.loadProgress = (totalDone, urls.count)
                    }
                }

                // 하나 끝나면 다음 1개 투입 → 동시 개수 maxConcurrent로 일정 유지
                while let result = await group.next() {
                    guard !Task.isCancelled else { continue }
                    pending.append(result)
                    done += 1
                    if pending.count >= batchSize { await flush(done) }
                    if next < count {
                        let i = next; next += 1
                        let url = urls[i]
                        group.addTask {
                            guard !Task.isCancelled else { return (i, nil, nil, 0) }
                            let ext = url.pathExtension.lowercased()
                            let isVideo = ["mov", "mp4", "m4v"].contains(ext)
                            let thumb = isVideo
                                ? await PhotoMetadata.loadVideoThumbnail(from: url)
                                : PhotoMetadata.loadThumbnail(from: url)
                            let coord = isVideo ? nil : PhotoMetadata.extractGPS(from: url)
                            let rating = isVideo ? 0 : RatingStore.readRating(from: url)
                            return (i, thumb, coord, rating)
                        }
                    }
                }
                await flush(done)
            }
            await MainActor.run { [weak self] in
                guard let self, self.currentFolderURL == folderURL else { return }
                self.isLoadingMetadata = false
            }
        }
    }

    // MARK: - Navigation

    func selectPhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        Logger.video.debug("selectPhoto idx=\(index) -> \(self.photos[index].name, privacy: .public) isVideo=\(self.photos[index].isVideo)")
        selectedIndex = index
        selectedIDs = [photos[index].id]
        selectionAnchor = index
    }

    func selectNext() {
        guard let idx = selectedIndex, !photos.isEmpty else { return }
        let nextIdx = idx + 1
        guard nextIdx < photos.count else { return }
        selectPhoto(at: nextIdx)
    }

    func selectPrevious() {
        guard let idx = selectedIndex, !photos.isEmpty else { return }
        let prevIdx = idx - 1
        guard prevIdx >= 0 else { return }
        selectPhoto(at: prevIdx)
    }

    // MARK: - Sibling folder navigation

    func selectNextSiblingFolder() {
        Task { await moveSiblingFolder(direction: 1) }
    }

    func selectPreviousSiblingFolder() {
        Task { await moveSiblingFolder(direction: -1) }
    }

    /// direction: +1 → 다음, -1 → 이전. wrap-around 포함.
    private func moveSiblingFolder(direction: Int) async {
        guard let current = currentFolderURL else { return }
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else { return }

        let siblings = await Task.detached(priority: .userInitiated) {
            PhotoBrowserModel.listSiblingPhotoFolders(in: parent)
        }.value

        guard !siblings.isEmpty else { return }

        let currentPath = current.standardizedFileURL.path
        let idx = siblings.firstIndex { $0.standardizedFileURL.path == currentPath } ?? -1

        let nextIdx: Int
        if idx < 0 {
            nextIdx = direction > 0 ? 0 : siblings.count - 1
        } else {
            let n = siblings.count
            guard n > 1 else { return }
            nextIdx = (idx + direction + n) % n
        }
        await loadFolder(url: siblings[nextIdx])
    }

    /// 부모 디렉터리의 자식 폴더 중 사진이 포함된 폴더만 사전순 반환.
    nonisolated static func listSiblingPhotoFolders(in parent: URL) -> [URL] {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            Logger.app.info("[siblings] parent unreadable: \(parent.path, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let dirs = contents.filter { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue
        }

        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v"]
        let withPhotos = dirs.filter { dir in
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { return false }
            return items.contains { exts.contains($0.pathExtension.lowercased()) }
        }

        return withPhotos.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Deletion (High #4)

    func handleDeleteKeyPress() {
        guard selectedPhoto != nil, pendingDeletePhoto == nil else { return }
        let skipConfirm = UserDefaults.standard.bool(forKey: "skipDeletePhotoConfirm")
        if skipConfirm {
            performDeleteSelectedPhoto()
        } else {
            pendingDeletePhoto = selectedPhoto
        }
    }

    func performDeleteSelectedPhoto() {
        let urls = selectedURLs
        guard !urls.isEmpty else { pendingDeletePhoto = nil; return }
        let idsToDelete = selectedIDs.isEmpty
            ? Set(urls.compactMap { u in photos.first(where: { $0.url == u })?.id })
            : selectedIDs
        var firstError: Error?
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { if firstError == nil { firstError = error } }
        }
        if let err = firstError { lastError = "삭제 실패: \(err.localizedDescription)" }
        let prevIdx = selectedIndex ?? 0
        photos.removeAll { idsToDelete.contains($0.id) }
        selectedIDs.removeAll()
        selectedIndex = photos.isEmpty ? nil : min(prevIdx, photos.count - 1)
        if let idx = selectedIndex { selectionAnchor = idx }
        pendingDeletePhoto = nil
    }

    // MARK: - Clipboard

    func copySelectedPhoto() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        clipboardURLs = urls
        clipboardMode = .copy
        writeToSystemPasteboard(urls)
    }

    func cutSelectedPhoto() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        clipboardURLs = urls
        clipboardMode = .cut
        writeToSystemPasteboard(urls)
    }

    func pasteIntoCurrentFolder() async {
        guard let dest = currentFolderURL, !clipboardURLs.isEmpty else { return }
        let mode = clipboardMode
        let urls = clipboardURLs
        do {
            switch mode {
            case .copy: try await copyFiles(urls, to: dest)
            case .cut:  try await moveFiles(urls, to: dest)
            }
            if mode == .cut { clipboardURLs = [] }
            await loadFolder(url: dest)
        } catch {
            lastError = "붙여넣기 실패: \(error.localizedDescription)"
        }
    }

    private func writeToSystemPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    // MARK: - File operations

    nonisolated static func uniqueDestination(_ source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext  = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            n += 1
        }
        return candidate
    }

    func copyFiles(_ urls: [URL], to folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for url in urls {
                let dst = PhotoBrowserModel.uniqueDestination(url, in: folder)
                try fm.copyItem(at: url, to: dst)
            }
        }.value
    }

    func moveFiles(_ urls: [URL], to folder: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for url in urls {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                    continue
                }
                let dst = PhotoBrowserModel.uniqueDestination(url, in: folder)
                try fm.moveItem(at: url, to: dst)
            }
        }.value
    }

    // MARK: - Drop confirmation

    func confirmDrop(mode: ClipboardMode) async {
        guard let op = pendingDropOperation else { return }
        pendingDropOperation = nil
        do {
            switch mode {
            case .copy: try await copyFiles(op.sources, to: op.destination)
            case .cut:  try await moveFiles(op.sources, to: op.destination)
            }
            if currentFolderURL == op.destination {
                await loadFolder(url: op.destination)
            } else if let cur = currentFolderURL,
                      mode == .cut,
                      op.sources.contains(where: { $0.deletingLastPathComponent() == cur }) {
                await loadFolder(url: cur)
            }
        } catch {
            lastError = "\(mode == .copy ? "복사" : "이동") 실패: \(error.localizedDescription)"
        }
    }

    func cancelDrop() {
        pendingDropOperation = nil
    }

    // MARK: - Folder operations

    func deleteItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        let parent = url.deletingLastPathComponent()
        folderChanged.send(parent)  // High #8
        if currentFolderURL == url {
            Task { await loadFolder(url: parent) }
        }
    }

    func renameItem(at url: URL, to newName: String) throws {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: newURL)
        let parent = url.deletingLastPathComponent()
        folderChanged.send(parent)  // High #8
        if currentFolderURL == url {
            Task { await loadFolder(url: newURL) }
        }
    }

    func createFolder(in parent: URL, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let target = parent.appendingPathComponent(trimmed, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            lastError = "이미 같은 이름의 폴더가 있습니다: \(trimmed)"
            return
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        folderChanged.send(parent)
    }
}

// MARK: - Image utilities (nonisolated — runs on background threads)

enum PhotoMetadata {
    nonisolated static func loadThumbnail(from url: URL) -> NSImage? {
        // 1) 캐시 우선 — 같은 폴더 재방문 시 디스크 IO 없이 즉시 반환
        if let cached = thumbnailCache.object(forKey: url as NSURL) { return cached }

        // 2) 디코딩 옵션
        //    - FromImageIfAbsent: EXIF에 임베디드 썸네일이 있으면 그걸 사용 (10×↑ 빠름).
        //      없을 때만 full image에서 다운샘플 — 기존 FromImageAlways 동작과 동일한 폴백.
        //    - CreateThumbnailWithTransform: EXIF 방향 보정 자동 적용.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 300
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(image, forKey: url as NSURL)
        return image
    }

    // High #7: downsampled display image (max 2048px) with LRU cache
    nonisolated static func loadDisplayImage(from url: URL, maxPixel: Int = 2048) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    // Extracts a thumbnail from the first available frame; respects track transform for portrait video.
    nonisolated static func loadVideoThumbnail(from url: URL) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) { return cached }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 300, height: 300)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter  = .positiveInfinity
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let cg: CGImage = try await gen.image(at: time).image
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            thumbnailCache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            Logger.video.error("video thumbnail 실패: \(url.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 파일이 읽을 수 있는 사진/동영상인지 판정. 0바이트이거나 디코딩 불가면 false.
    nonisolated static func isReadablePhoto(_ url: URL) -> Bool {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == 0 {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) { return true }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              CGImageSourceCreateThumbnailAtIndex(
                  src, 0,
                  [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                   kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary
              ) != nil
        else { return false }
        return true
    }

    nonisolated static func extractGPS(from url: URL) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else {
            return nil
        }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
        let latitude = latRef == "S" ? -lat : lat
        let longitude = lonRef == "W" ? -lon : lon
        let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coord) else { return nil }
        return coord
    }
}

// NSCache holds up to ~50 display images; evicts LRU automatically
private let imageCache: NSCache<NSURL, NSImage> = {
    let c = NSCache<NSURL, NSImage>()
    c.countLimit = 50
    return c
}()

// 썸네일 캐시 — 폴더 재방문 시 회색 placeholder 단계를 건너뛰기 위함.
// 썸네일은 약 60KB(300px 안팎)이므로 1500개 보유 시 ~90MB.
// 여러 폴더를 오가며 작업하는 경우를 폭넓게 cover하려면 500으론 부족.
private let thumbnailCache: NSCache<NSURL, NSImage> = {
    let c = NSCache<NSURL, NSImage>()
    c.countLimit = 1500
    return c
}()
