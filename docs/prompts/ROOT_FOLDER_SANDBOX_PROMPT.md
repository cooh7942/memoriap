# Root Folder 지정 + Sandbox 전환 — 코드 수정 요청

## 목표

1. `com.apple.security.app-sandbox`를 `true`로 전환
2. 앱이 사용할 사진 루트 폴더를 사용자가 직접 지정하도록 변경
3. Security-Scoped Bookmark로 지정한 폴더를 영구 저장 → 재실행 시 자동 복원
4. 외장 디스크(USB 등) 지정을 지원하되, 연결이 끊겼을 때 안전하게 처리
5. 현재 `SidebarView`의 `loadRootFolders()` (= `/` 전체 탐색) 제거

---

## 수정 대상 파일

- `pinframe/pinframe.entitlements`
- `pinframe/pinframe/PhotoBrowserModel.swift`
- `pinframe/pinframe/SidebarView.swift`
- `pinframe/pinframe/ContentView.swift`

---

## 1. Entitlements 변경

`pinframe/pinframe.entitlements` 를 아래로 교체:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

> **주의**: `project.pbxproj`에서 `CODE_SIGN_ENTITLEMENTS`가 이 파일을 가리키는지
> 확인하고, `ENABLE_USER_SELECTED_FILES = readonly;` 줄이 있으면 `readwrite`로 변경.

---

## 2. RootFolderStore — 새 파일 `RootFolderStore.swift` 추가

Security-Scoped Bookmark의 생성/저장/복원을 전담하는 타입.
`PhotoBrowserModel`과 `SidebarView` 모두 이 타입을 통해서만 루트 폴더를 다룬다.

```swift
import Foundation

/// Security-Scoped Bookmark 기반 루트 폴더 목록 관리.
/// - UserDefaults에 `[Data]`(북마크 배열)로 저장한다.
/// - 샌드박스 환경에서 앱 재실행 후에도 접근권을 유지한다.
@MainActor
final class RootFolderStore: ObservableObject {

    static let shared = RootFolderStore()

    // 현재 접근 가능한 루트 폴더 URL 목록 (외장 디스크가 없으면 그 항목은 빠짐)
    @Published private(set) var roots: [URL] = []

    // 복원에 실패한(= 외장 디스크 분리 등) 경로 이름 목록 — 경고 메시지용
    @Published private(set) var unavailableNames: [String] = []

    private let defaultsKey = "rootFolderBookmarks"
    // 접근 중인 URL → 반드시 stopAccessing 해야 함
    private var accessingURLs: [URL] = []

    private init() {}

    // MARK: - 앱 시작 시 복원

    /// 저장된 북마크를 모두 복원한다.
    /// - Returns: 유효한 루트가 하나라도 있으면 true, 전부 실패하면 false.
    @discardableResult
    func restoreAll() -> Bool {
        stopAllAccess()
        guard let bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data],
              !bookmarks.isEmpty else {
            return false
        }

        var valid: [URL] = []
        var unavailable: [String] = []
        var refreshed: [Data] = []

        for data in bookmarks {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard url.startAccessingSecurityScopedResource() else {
                    // 접근 불가 — 외장 디스크 분리 등
                    unavailable.append(url.lastPathComponent)
                    continue
                }
                // 볼륨이 마운트되어 있지 않으면 isStale=false 여도 FileManager가 실패할 수 있으므로
                // 실제 존재 여부도 확인
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    url.stopAccessingSecurityScopedResource()
                    unavailable.append(url.lastPathComponent)
                    continue
                }
                accessingURLs.append(url)
                valid.append(url)
                // stale이면 북마크 갱신
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                    refreshed.append(fresh)
                } else {
                    refreshed.append(data)
                }
            } catch {
                // 북마크 자체가 손상 — 폴더 이름을 알 수 없으므로 기록만
                unavailable.append("(알 수 없는 폴더)")
            }
        }

        // 갱신된 북마크 목록으로 덮어쓰기 (유효한 것만 유지)
        if refreshed.count != bookmarks.count || refreshed != bookmarks {
            UserDefaults.standard.set(refreshed, forKey: defaultsKey)
        }

        roots = valid
        unavailableNames = unavailable
        return !valid.isEmpty
    }

    // MARK: - 폴더 추가 (NSOpenPanel 결과)

    /// NSOpenPanel로 선택한 URL을 북마크로 저장하고 roots에 추가.
    func add(url: URL) {
        guard !roots.contains(url) else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = (UserDefaults.standard.array(forKey: defaultsKey) as? [Data]) ?? []
            bookmarks.append(data)
            UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
            accessingURLs.append(url)
            roots.append(url)
        } catch {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - 폴더 제거

    func remove(url: URL) {
        if let idx = accessingURLs.firstIndex(of: url) {
            accessingURLs[idx].stopAccessingSecurityScopedResource()
            accessingURLs.remove(at: idx)
        }
        roots.removeAll { $0 == url }
        // 북마크 목록에서도 제거 (경로가 같은 것)
        rebuildBookmarks()
    }

    // MARK: - 볼륨 마운트 해제 시 처리

    /// NSWorkspace.didUnmountNotification 수신 시 호출.
    /// - Returns: 제거된 루트 폴더 이름 목록 (비어 있으면 변화 없음)
    @discardableResult
    func handleVolumeUnmount(volumeURL: URL) -> [String] {
        let removed = roots.filter { $0.path.hasPrefix(volumeURL.path) }
        guard !removed.isEmpty else { return [] }
        for url in removed {
            remove(url: url)
        }
        return removed.map { $0.lastPathComponent }
    }

    // MARK: - 저장된 북마크가 없는지 확인

    var hasNoSavedRoots: Bool {
        let bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data]
        return bookmarks == nil || bookmarks!.isEmpty
    }

    // MARK: - 내부

    private func stopAllAccess() {
        for url in accessingURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessingURLs = []
    }

    private func rebuildBookmarks() {
        // 현재 roots를 다시 북마크로 직렬화
        let bookmarks: [Data] = accessingURLs.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope)
        }
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }
}
```

---

## 3. PhotoBrowserModel.swift 수정

### 3-a. `customFavorites` — Security-Scoped Bookmark로 교체

현재 `customFavorites`는 경로(String)로 저장하고 있다.
루트 폴더가 Security-Scoped Bookmark로 관리되므로, 즐겨찾기는
**루트 하위의 서브폴더**만 허용하면 별도 북마크 없이 경로만 저장해도 된다.
루트 접근권이 살아 있는 동안 하위 경로는 자유롭게 접근 가능하기 때문이다.
따라서 `customFavorites` 저장 방식은 현행(경로 String) 유지.

### 3-b. `restoreLastFolder()` — bookmark 기반으로 교체

기존 `restoreLastFolder()`를 제거하고, 아래 흐름으로 대체:

```swift
// PhotoBrowserModel.init() 에서 호출
func restoreSession() async {
    // 1. RootFolderStore가 북마크를 복원
    let hasValid = RootFolderStore.shared.restoreAll()

    // 2. 마지막으로 보던 폴더 경로 복원 시도
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
```

### 3-c. `loadFolder(url:)` — 변경 없음

기존 코드 그대로 유지. 접근권은 RootFolderStore가 이미 확보해 둔 상태이므로
`FileManager` 호출이 정상 동작한다.

### 3-d. 볼륨 언마운트 대응 프로퍼티 추가

```swift
// 볼륨 언마운트로 인해 현재 폴더가 사라진 경우 true
@Published var currentFolderBecameUnavailable = false
```

---

## 4. ContentView.swift 수정

### 4-a. 앱 시작 흐름 — 폴더 선택 화면 제어

```swift
struct ContentView: View {
    @StateObject private var model = PhotoBrowserModel()
    @StateObject private var folderStore = RootFolderStore.shared  // @StateObject 아님, 공유 인스턴스
    @ObservedObject private var folderStore = RootFolderStore.shared  // ObservedObject로 참조
    @State private var showFolderPicker = false
    @State private var showUnavailableAlert = false
    @State private var unmountedFolderNames: [String] = []
    // ... (기존 eventMonitor, skipDeleteConfirm 유지)

    var body: some View {
        Group {
            if folderStore.roots.isEmpty && !showFolderPicker {
                // 루트 폴더가 없는 상태 — 온보딩 화면
                FolderPickerOnboardingView(onPick: { openFolderPicker() })
            } else {
                // 정상 메인 화면
                mainLayout
            }
        }
        .task {
            // 앱 시작 시 복원
            await model.restoreSession()

            // 복원에 실패한 폴더가 있으면 경고
            if !RootFolderStore.shared.unavailableNames.isEmpty {
                unmountedFolderNames = RootFolderStore.shared.unavailableNames
                showUnavailableAlert = true
            }

            // 저장된 루트가 하나도 없으면 폴더 선택 화면
            if RootFolderStore.shared.roots.isEmpty {
                showFolderPicker = true
                openFolderPicker()
            }
        }
        // 볼륨 언마운트 → 현재 폴더가 사라진 경우
        .onChange(of: model.currentFolderBecameUnavailable) { _, became in
            if became {
                model.currentFolderBecameUnavailable = false
                if RootFolderStore.shared.roots.isEmpty {
                    // 유효한 루트가 없음 → 폴더 선택 화면으로
                    openFolderPicker()
                }
                // 유효한 루트가 남아 있으면 경고만 표시하고 계속
                unmountedFolderNames = RootFolderStore.shared.unavailableNames
                showUnavailableAlert = true
            }
        }
        // 외장 디스크 분리 경고 alert
        .alert(
            "연결이 끊긴 폴더",
            isPresented: $showUnavailableAlert
        ) {
            Button("확인", role: .cancel) {
                unmountedFolderNames = []
            }
        } message: {
            Text("다음 폴더에 접근할 수 없습니다 (외장 디스크가 분리되었거나 경로가 변경되었을 수 있습니다):\n\n"
                 + unmountedFolderNames.map { "• \($0)" }.joined(separator: "\n"))
        }
        // ... (기존 delete confirm alert, error alert 유지)
    }

    private var mainLayout: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
            CenterView(model: model)
                .frame(minWidth: 400)
            PhotoMapView(model: model)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 500)
        }
        .frame(minWidth: 1100, minHeight: 700)
        // ... (기존 toolbar, eventMonitor 유지)
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "사진 폴더의 루트를 선택하세요"
        panel.prompt = "선택"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            RootFolderStore.shared.add(url: url)
            Task { await model.loadFolder(url: url) }
        }
    }
}
```

### 4-b. 온보딩 화면 컴포넌트

```swift
struct FolderPickerOnboardingView: View {
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            Text("사진 폴더 선택")
                .font(.title2).bold()
            Text("사진이 저장된 루트 폴더를 선택하면\n하위 폴더의 모든 사진을 탐색할 수 있습니다.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("폴더 선택…", action: onPick)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

---

## 5. SidebarView.swift 수정

### 5-a. `loadRootFolders()` 제거

다음 함수를 **완전히 삭제**:

```swift
// 삭제
private func loadRootFolders() {
    let urls = SidebarTreeModel.loadDirectChildren(of: URL(fileURLWithPath: "/"))
    locationsTree.setRoots(urls)
}
```

### 5-b. "위치" 섹션 → 사용자 지정 루트 폴더 섹션으로 교체

`locationsTree`와 `SidebarTreeModel` 인스턴스 자체는 유지하되,
루트 노드 소스를 `RootFolderStore.shared.roots`로 변경한다.

```swift
@ObservedObject private var folderStore = RootFolderStore.shared
```

`onAppear`에서 `loadRootFolders()` 호출을 제거하고,
`folderStore.roots` 변화에 반응하도록:

```swift
.onChange(of: folderStore.roots) { _, newRoots in
    locationsTree.setRoots(newRoots)
}
.onAppear {
    // loadRootFolders() 제거 — 대신 현재 roots로 초기화
    locationsTree.setRoots(folderStore.roots)
    loadVolumes()
    // ... (기존 mountObserver, unmountObserver 등록 유지)
}
```

### 5-c. 볼륨 언마운트 처리 — SidebarView에 추가

기존 `unmountObserver` 핸들러를 확장:

```swift
unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didUnmountNotification,
    object: nil, queue: .main
) { notification in
    // 1. 장치 섹션 갱신 (기존 코드)
    loadVolumes()

    // 2. 분리된 볼륨 URL 추출
    guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }

    // 3. RootFolderStore에서 해당 볼륨의 루트 제거 + 이름 수집
    let removed = RootFolderStore.shared.handleVolumeUnmount(volumeURL: volumeURL)
    guard !removed.isEmpty else { return }

    // 4. 현재 폴더가 분리된 볼륨 위에 있었다면 model에 알림
    if let current = model.currentFolderURL,
       current.path.hasPrefix(volumeURL.path) {
        model.currentFolderURL = nil
        model.photos = []
        model.selectedIndex = nil
        model.currentFolderBecameUnavailable = true
    }
    // 5. locationsTree 루트 업데이트
    locationsTree.setRoots(RootFolderStore.shared.roots)
}
```

### 5-d. "폴더 추가" 버튼 — 사이드바 상단에 추가

사이드바 하단(또는 "사진 폴더" 섹션 헤더 우측)에 + 버튼:

```swift
Section(header: HStack {
    Text("사진 폴더")
    Spacer()
    Button { openFolderPicker() } label: {
        Image(systemName: "plus")
            .font(.caption)
    }
    .buttonStyle(.plain)
    .help("사진 폴더 추가")
}) {
    ForEach(locationsTree.visibleNodes) { node in
        FlatFolderRow(
            node: node,
            isExpanded: locationsTree.isExpanded(node.url),
            isExpandable: true,
            onToggle: { locationsTree.toggle(node.url) },
            model: model
        )
        .id(node.url)
    }
}
```

`SidebarView` 내부에 `openFolderPicker()` 함수 추가:

```swift
private func openFolderPicker() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "추가할 사진 폴더를 선택하세요"
    panel.prompt = "추가"
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        RootFolderStore.shared.add(url: url)
    }
}
```

### 5-e. 루트 폴더 우클릭 메뉴 — "목록에서 제거" 추가

`FlatFolderRow`의 `contextMenu`에서, 해당 URL이 루트 폴더인 경우
"목록에서 제거" 항목을 표시:

```swift
// FlatFolderRow.contextMenu 내부
let isRoot = RootFolderStore.shared.roots.contains(url)

if isRoot {
    Button("이 폴더를 목록에서 제거", role: .destructive) {
        RootFolderStore.shared.remove(url: url)
    }
    Divider()
}
// ... (기존 즐겨찾기/이름변경/삭제 항목 유지)
```

---

## 6. 처리 시나리오 요약

| 시나리오 | 동작 |
|----------|------|
| 최초 실행 (저장된 루트 없음) | 온보딩 화면 → NSOpenPanel → 루트 등록 |
| 재실행 (로컬 루트 정상) | 북마크 복원 → 마지막 폴더 자동 로드 |
| 재실행 (외장 루트만 있고 분리됨) | 경고 alert → 온보딩 화면(폴더 선택) |
| 재실행 (로컬 + 외장 혼합, 외장만 분리) | 경고 alert → 로컬 루트로 정상 시작 |
| 앱 실행 중 외장 디스크 분리 | 경고 alert / 현재 폴더가 그 디스크면 photos 초기화, 남은 루트 없으면 온보딩 화면 |
| 폴더 추가 버튼 클릭 | NSOpenPanel → 북마크 저장 → 사이드바 트리에 즉시 반영 |
| 루트 폴더 우클릭 → 제거 | 북마크 삭제, 접근권 해제, 사이드바에서 제거 |

---

## 7. 작업 후 확인 항목

1. `codesign -d --entitlements :- <앱 경로>` 출력에 `app-sandbox = true`, `user-selected.read-write = true` 확인
2. 최초 실행 시 온보딩 화면이 표시되고 NSOpenPanel이 정상 동작하는지 확인
3. 앱 재실행 후 마지막 폴더가 자동 복원되는지 확인
4. USB 연결 → 폴더 선택 → USB 분리 → 재실행 시 경고 후 온보딩 화면으로 이동하는지 확인
5. 로컬 폴더 + USB 폴더 동시 등록 상태에서 USB 분리 → 경고만 표시되고 로컬 폴더로 계속 동작하는지 확인
6. 사이드바 "+" 버튼으로 폴더를 추가하면 트리에 즉시 반영되는지 확인
7. `/` 또는 시스템 경로에 직접 접근하는 코드가 없는지 grep으로 확인:
   ```bash
   grep -rn 'fileURLWithPath: "/"' pinframe/
   grep -rn 'URL(fileURLWithPath: "/")' pinframe/
   ```
