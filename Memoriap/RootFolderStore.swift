import Foundation
import Combine

/// Security-Scoped Bookmark 기반 루트 폴더 목록 관리.
///
/// - `savedBookmarks` (메모리 + UserDefaults): 진실의 원천. 사용자가 명시적으로 제거하지 않는 한 절대 삭제하지 않는다.
/// - `roots`: 현재 접근 가능한 URL 목록 — 런타임의 일시적 뷰.
/// - 볼륨 분리 시 roots에서만 제거하고 savedBookmarks는 보존 → 재연결 시 자동 복원.
@MainActor
final class RootFolderStore: ObservableObject {

    static let shared = RootFolderStore()

    @Published private(set) var roots: [URL] = []
    @Published private(set) var unavailableNames: [String] = []

    private let defaultsKey = "rootFolderBookmarks"
    private var accessingURLs: [URL] = []
    // 북마크 Data를 메모리에 보유 — UserDefaults를 항상 신뢰할 수 있도록 동기화 유지
    private var savedBookmarks: [Data] = []

    private init() {
        savedBookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
    }

    // MARK: - 앱 시작 시 복원

    /// 앱 시작 시 한 번만 호출. 저장된 북마크로 roots를 초기화한다.
    /// 복원 실패한 북마크는 UserDefaults에 보존 — 디스크 재연결 시 복원 가능.
    /// 두 번 이상 호출되어도 기존 access를 끊지 않는다.
    @discardableResult
    func bootstrapOnLaunch() async -> Bool {
        guard accessingURLs.isEmpty else { return !roots.isEmpty }
        await rebuildRootsFromSavedBookmarks()
        return !roots.isEmpty
    }

    /// 외장 디스크가 다시 마운트됐거나 사용자가 재시도할 때 호출.
    /// UserDefaults 데이터는 그대로 두고 런타임 roots만 재계산한다.
    func retryUnavailable() async {
        await rebuildRootsFromSavedBookmarks()
    }

    // MARK: - 핵심 복원 로직

    private struct ProbeResult: Sendable {
        let url: URL?
        let accessible: Bool
        let startedAccess: Bool
        let freshBookmark: Data?
    }

    private var isRebuilding = false
    private var needsRebuild = false

    private func rebuildRootsFromSavedBookmarks() async {
        // 복원 중에 마운트 알림 등으로 다시 불리면 끝난 뒤 한 번 더 돌린다 (동시 실행 방지).
        guard !isRebuilding else { needsRebuild = true; return }
        isRebuilding = true
        defer { isRebuilding = false }
        repeat {
            needsRebuild = false
            await rebuildOnce()
        } while needsRebuild
    }

    private func rebuildOnce() async {
        let bookmarks = savedBookmarks
        let alreadyAccessing = Set(accessingURLs)

        // 북마크 해석·존재 확인은 연결이 끊긴 네트워크 드라이브에서 멈출 수 있으므로
        // 메인 스레드 밖에서, 북마크별로 병렬·타임아웃 적용해 실행한다.
        let results: [Int: ProbeResult] = await withTaskGroup(of: (Int, ProbeResult?).self) { group in
            for (i, data) in bookmarks.enumerated() {
                group.addTask {
                    let result = await FileProbe.run({
                        Self.probe(bookmark: data, alreadyAccessing: alreadyAccessing)
                    }, onLateResult: { late in
                        // 시간 초과 후에 뒤늦게 access를 얻었다면 반납
                        if late.startedAccess { late.url?.stopAccessingSecurityScopedResource() }
                    })
                    return (i, result)
                }
            }
            var collected: [Int: ProbeResult] = [:]
            for await (i, result) in group {
                if let result { collected[i] = result }
            }
            return collected
        }

        var valid: [URL] = []
        var unavailable: [String] = []
        var newAccessingURLs: [URL] = []

        for (i, data) in bookmarks.enumerated() {
            guard let result = results[i] else {
                // 시간 초과 — 응답 없는 네트워크 드라이브 등
                unavailable.append(Self.displayName(ofBookmark: data))
                continue
            }
            guard let url = result.url else {
                // 북마크 자체를 못 풀면 이름을 알 수 없음 — UserDefaults는 보존
                unavailable.append(Self.displayName(ofBookmark: data))
                continue
            }
            guard result.accessible else {
                unavailable.append(url.lastPathComponent)
                continue
            }
            newAccessingURLs.append(url)
            valid.append(url)
            // stale이면 북마크만 갱신 (영구 삭제 아님 — 같은 폴더의 새 형태)
            if let fresh = result.freshBookmark, i < savedBookmarks.count, savedBookmarks[i] == data {
                savedBookmarks[i] = fresh
            }
        }

        // 복원하는 동안 사용자가 add()로 추가한 루트는 유지
        for url in accessingURLs where !alreadyAccessing.contains(url) && !newAccessingURLs.contains(url) {
            newAccessingURLs.append(url)
            valid.append(url)
        }
        // 기존에 access 중이었지만 새 목록에 없는 것은 정리
        for old in accessingURLs where !newAccessingURLs.contains(old) {
            old.stopAccessingSecurityScopedResource()
        }
        accessingURLs = newAccessingURLs
        roots = valid
        unavailableNames = unavailable
        // stale 갱신이 있었을 수 있으므로 UserDefaults와 동기화 (삭제 없음)
        UserDefaults.standard.set(savedBookmarks, forKey: defaultsKey)
    }

    /// 백그라운드 스레드에서 실행 — 북마크 해석, access 시작, 디렉터리 존재 확인.
    nonisolated private static func probe(bookmark data: Data, alreadyAccessing: Set<URL>) -> ProbeResult {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            // 마운트되지 않은 네트워크 볼륨을 자동으로 마운트하려다 멈추지 않도록
            options: [.withSecurityScope, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return ProbeResult(url: nil, accessible: false, startedAccess: false, freshBookmark: nil)
        }
        // 이미 access 중이면 재호출하지 않음
        if alreadyAccessing.contains(url) {
            return ProbeResult(url: url, accessible: true, startedAccess: false, freshBookmark: nil)
        }
        guard url.startAccessingSecurityScopedResource() else {
            return ProbeResult(url: url, accessible: false, startedAccess: false, freshBookmark: nil)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            return ProbeResult(url: url, accessible: false, startedAccess: false, freshBookmark: nil)
        }
        let fresh = isStale ? try? url.bookmarkData(options: .withSecurityScope) : nil
        return ProbeResult(url: url, accessible: true, startedAccess: true, freshBookmark: fresh)
    }

    /// 북마크 데이터에 저장된 폴더 이름 (파일 시스템 접근 없음).
    nonisolated private static func displayName(ofBookmark data: Data) -> String {
        let values = URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: data)
        return values?.name ?? "(알 수 없는 폴더)"
    }

    // MARK: - 폴더 추가 (NSOpenPanel 결과)

    func add(url: URL) {
        guard !roots.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            savedBookmarks.append(data)
            UserDefaults.standard.set(savedBookmarks, forKey: defaultsKey)
            accessingURLs.append(url)
            roots.append(url)
        } catch {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - 폴더 제거 (사용자의 명시적 요청 시에만)

    func remove(url: URL) {
        if let idx = accessingURLs.firstIndex(of: url) {
            accessingURLs[idx].stopAccessingSecurityScopedResource()
            accessingURLs.remove(at: idx)
        }
        roots.removeAll { $0 == url }
        // 이 URL에 해당하는 savedBookmarks 항목도 함께 영구 제거
        savedBookmarks.removeAll { data in
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return false }
            return resolved == url
        }
        UserDefaults.standard.set(savedBookmarks, forKey: defaultsKey)
    }

    // MARK: - 볼륨 마운트 해제 시 처리

    /// 런타임에서만 제거 — savedBookmarks와 UserDefaults는 보존.
    /// 디스크 재연결 시 retryUnavailable()로 자동 복원 가능.
    @discardableResult
    func handleVolumeUnmount(volumeURL: URL) -> [String] {
        let removed = roots.filter { $0.path.hasPrefix(volumeURL.path) }
        guard !removed.isEmpty else { return [] }
        for url in removed {
            if let idx = accessingURLs.firstIndex(of: url) {
                accessingURLs[idx].stopAccessingSecurityScopedResource()
                accessingURLs.remove(at: idx)
            }
            roots.removeAll { $0 == url }
            unavailableNames.append(url.lastPathComponent)
        }
        // ⚠️ savedBookmarks와 UserDefaults는 건드리지 않는다.
        return removed.map { $0.lastPathComponent }
    }

    // MARK: - 저장된 북마크가 없는지 확인

    var hasNoSavedRoots: Bool {
        savedBookmarks.isEmpty
    }

    // MARK: - 동영상 재생용 헬퍼

    /// 주어진 파일 URL을 포함하는, 접근 권한이 있는 루트 URL을 반환.
    func root(containing url: URL) -> URL? {
        let target = url.standardizedFileURL.path
        return roots.first { target.hasPrefix($0.standardizedFileURL.path) }
    }
}
