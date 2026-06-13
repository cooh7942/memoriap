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
    func bootstrapOnLaunch() -> Bool {
        guard accessingURLs.isEmpty else { return !roots.isEmpty }
        rebuildRootsFromSavedBookmarks()
        return !roots.isEmpty
    }

    /// 외장 디스크가 다시 마운트됐거나 사용자가 재시도할 때 호출.
    /// UserDefaults 데이터는 그대로 두고 런타임 roots만 재계산한다.
    func retryUnavailable() {
        rebuildRootsFromSavedBookmarks()
    }

    // MARK: - 핵심 복원 로직

    private func rebuildRootsFromSavedBookmarks() {
        var valid: [URL] = []
        var unavailable: [String] = []
        var newAccessingURLs: [URL] = []

        for i in 0..<savedBookmarks.count {
            let data = savedBookmarks[i]
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                // 이미 access 중이면 재호출하지 않음
                if accessingURLs.contains(url) {
                    valid.append(url)
                    newAccessingURLs.append(url)
                    continue
                }
                guard url.startAccessingSecurityScopedResource() else {
                    unavailable.append(url.lastPathComponent)
                    continue
                }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    url.stopAccessingSecurityScopedResource()
                    unavailable.append(url.lastPathComponent)
                    continue
                }
                newAccessingURLs.append(url)
                valid.append(url)
                // stale이면 북마크만 갱신 (영구 삭제 아님 — 같은 폴더의 새 형태)
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                    savedBookmarks[i] = fresh
                }
            } catch {
                // 북마크 자체를 못 풀면 이름을 알 수 없음 — UserDefaults는 보존
                unavailable.append("(알 수 없는 폴더)")
            }
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
