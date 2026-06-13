# pinframe 코드 수정 요청 프롬프트

아래 작업을 우선순위(Critical → High → Medium) 순서로 수행해 주세요. 각 항목은 독립적으로 적용 가능하지만, **Critical 항목을 먼저 끝낸 뒤** High/Medium으로 진행해 주세요. 코드 수정 후에는 변경된 파일 목록과 핵심 변경점을 요약해 주세요.

---

## 프로젝트 개요

- macOS SwiftUI 사진 뷰어 앱 (pinframe)
- 3분할 레이아웃: 좌측 폴더 트리 / 가운데 사진+썸네일 / 우측 지도(GPS)
- 지원 포맷: jpg, jpeg, png, heic
- 주요 파일: `pinframeApp.swift`, `ContentView.swift`, `SidebarView.swift`, `CenterView.swift`, `PhotoMapView.swift`, `PhotoBrowserModel.swift`
- Xcode 프로젝트: `pinframe.xcodeproj`
- 배포 타깃: macOS 26.3 / Swift 5

---

## 🔴 Critical (반드시 수정)

### 1. App Sandbox 권한을 Read/Write로 변경

**현재 문제:** `project.pbxproj`의 `ENABLE_USER_SELECTED_FILES = readonly` 설정 때문에 `FileManager.trashItem` / `moveItem` 호출이 모두 실패함. 사진 삭제, 폴더 삭제, 폴더 이름 변경 기능이 모두 동작하지 않음.

**수정 사항:**
- 빌드 설정의 `ENABLE_USER_SELECTED_FILES` 값을 `readwrite`로 변경
- 또는 `.entitlements` 파일을 생성/수정하여 다음 권한을 추가:
  ```xml
  <key>com.apple.security.files.user-selected.read-write</key>
  <true/>
  <key>com.apple.security.assets.pictures.read-write</key>
  <true/>
  <key>com.apple.security.downloads.read-write</key>
  <true/>
  ```
- 즐겨찾기(`SidebarView.favorites`)에서 `~/Pictures`, `~/Downloads`에 직접 접근하므로 위 권한이 함께 필요.

### 2. 마지막 폴더 기억을 Security-Scoped Bookmark로 구현

**현재 문제:** `PhotoBrowserModel.loadFolder`가 `UserDefaults`에 path 문자열만 저장. Sandbox 앱은 다음 실행 시 같은 path로 접근하면 거부됨. 결과적으로 "마지막 폴더 위치 기억" 요구사항이 동작하지 않음.

**수정 사항:**
- `loadFolder(url:)`에서 `url.bookmarkData(options: .withSecurityScope, ...)`로 북마크를 만들어 `UserDefaults`에 `Data`로 저장
- `restoreLastFolder()`에서 `URL(resolvingBookmarkData:options:.withSecurityScope, ...)`로 복원
- 복원된 URL은 `startAccessingSecurityScopedResource()` 호출 후 사용, 폴더 전환/앱 종료 시 `stopAccessingSecurityScopedResource()` 호출
- `bookmarkDataIsStale`이 true면 새로 북마크 생성 후 저장
- 자식 폴더 접근은 부모의 보안 스코프 안에서 가능하므로 추가 처리 불필요

### 3. 외장 USB 핫플러그 자동 감지

**현재 문제:** `SidebarView.loadVolumes()`가 `onAppear`에서 한 번만 호출됨. 앱 실행 중 USB를 꽂거나 빼도 사이드바가 업데이트되지 않음.

**수정 사항:**
- `NSWorkspace.shared.notificationCenter`에서 다음 두 알림을 구독:
  - `NSWorkspace.didMountNotification`
  - `NSWorkspace.didUnmountNotification`
- 알림 수신 시 `loadVolumes()` 재실행하여 `volumes` 상태 갱신
- 옵저버는 뷰가 사라질 때 `removeObserver`로 정리

---

## 🟠 High (사용자 경험에 큰 영향)

### 4. Delete 키 처리를 글로벌 단축키로 + 삭제 확인 다이얼로그 추가

**현재 문제:**
- `.onKeyPress(.delete)`가 `PhotoDisplayArea`의 포커스에 의존. 사이드바·지도·툴바를 클릭한 뒤에는 가운데 사진을 다시 클릭해야 단축키가 동작.
- 사진 삭제 시 확인 다이얼로그가 없음(폴더 삭제는 있는데 사진은 없는 비대칭).

**수정 사항:**
- `pinframeApp.swift`의 `.commands`에 `CommandMenu` 또는 `CommandGroup`을 추가하여 Delete/Backspace 키를 글로벌 단축키로 등록
  - 또는 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`로 윈도우 레벨에서 처리
- 삭제 직전 confirm alert 표시(예: "이 사진을 휴지통으로 이동하시겠습니까?")
- 첫 삭제 시 "다시 묻지 않기" 체크박스를 제공하면 더 좋음(`UserDefaults`로 저장)
- 삭제 실패 시 `print` 대신 사용자에게 보이는 alert/toast로 알림

### 5. 썸네일·GPS 메타데이터 추출을 병렬 처리

**현재 문제:** `PhotoBrowserModel.loadPhotos`가 `for` 루프에서 `await`로 한 장씩 직렬 처리. 500장 이상이면 핀이 띄엄띄엄 수 초~수십 초에 걸쳐 나타남.

**수정 사항:**
- `withTaskGroup`을 사용해 동시 4~8개씩 병렬 처리
- 결과가 도착하는 대로 `photos[i].thumbnail`, `photos[i].coordinate` 갱신
- `currentFolderURL == folderURL` 가드 유지 (폴더 전환 시 중단)
- 동시성 수준을 상수로 추출(예: `private let metadataConcurrency = 6`)

```swift
await withTaskGroup(of: (Int, NSImage?, CLLocationCoordinate2D?).self) { group in
    for (i, url) in photoURLs.enumerated() {
        group.addTask(priority: .utility) {
            (i, PhotoMetadata.loadThumbnail(from: url),
                PhotoMetadata.extractGPS(from: url))
        }
    }
    for await (i, thumb, coord) in group {
        guard currentFolderURL == folderURL, i < photos.count else { continue }
        photos[i].thumbnail = thumb
        photos[i].coordinate = coord
        metadataVersion += 1
    }
}
```

### 6. 로딩 상태를 두 단계로 분리

**현재 문제:** `isLoading`이 파일 목록만 읽으면 false가 됨. 그 후 수 초간 썸네일이 비고 핀이 점점 찍히지만 사용자에게는 "로딩 끝"으로 보임.

**수정 사항:**
- `@Published var isLoadingFiles: Bool` (파일 목록 로딩)
- `@Published var isLoadingMetadata: Bool` (썸네일/GPS 로딩)
- 또는 `@Published var loadProgress: (done: Int, total: Int)?`를 두고 툴바/상태 영역에 "메타데이터 분석 1234/5000" 표시
- 기존 `isLoading` 참조처(ContentView, CenterView)도 의도에 맞게 갱신

### 7. 풀해상도 이미지 다운샘플링

**현재 문제:** `PhotoImageView`가 `NSImage(contentsOf: url)`로 원본을 그대로 로드. 8000×5000짜리 이미지를 빠르게 넘기면 메모리 100~200MB×N으로 누적되어 보일 수 있음.

**수정 사항:**
- `PhotoMetadata`에 `loadDisplayImage(from url: URL, maxPixel: Int) -> NSImage?` 추가
- `CGImageSourceCreateThumbnailAtIndex`와 `kCGImageSourceThumbnailMaxPixelSize` 옵션을 사용해 화면 해상도 기준(예: 2048px)으로 다운샘플링
- `kCGImageSourceShouldCacheImmediately: true`로 즉시 디코딩
- 가능하면 최근 N장 이미지를 LRU로 캐시(`NSCache<NSURL, NSImage>`)

```swift
static func loadDisplayImage(from url: URL, maxPixel: Int = 2048) -> NSImage? {
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    else { return nil }
    return NSImage(cgImage: cg, size: .init(width: cg.width, height: cg.height))
}
```

### 8. 폴더 트리에서 rename/delete 후 부모 폴더 자동 새로고침

**현재 문제:** `PhotoBrowserModel.renameItem`/`deleteItem`은 `currentFolderURL`이 변경된 URL과 일치할 때만 reload. 사이드바에서 선택되지 않은 하위 폴더의 이름을 바꾸거나 삭제하면 부모 `FolderTreeRow`의 `children` 배열은 그대로라 UI에 옛 이름이 남음.

**수정 사항:**
- `PhotoBrowserModel`에 `let folderChanged = PassthroughSubject<URL, Never>()` 추가 (Combine)
- `renameItem` / `deleteItem` 성공 후 변경된 항목의 **부모 URL**을 publish
- `FolderTreeRow`가 `onReceive(model.folderChanged)`로 자신의 URL과 일치하면 `loadChildren()` 재호출 + `isLoaded = true` 유지
- 또는 모델 전체에 `@Published var sidebarRefreshToken: UUID`를 두고 각 행이 `onChange`로 자식 재로딩

---

## 🟡 Medium (견고성 / 폴리시)

### 9. PhotoItem Equatable을 전체 비교로 변경

**현재 문제:** `PhotoItem.==`가 `id`만 비교. thumbnail/coordinate가 채워져도 SwiftUI가 "변경 없음"으로 판단할 수 있어 `metadataVersion`이라는 우회 트릭이 필요했음.

**수정 사항:**
- 커스텀 `==` 구현을 제거하고 컴파일러가 자동 합성하도록 두거나, `id`/`url`/`thumbnail`/`coordinate`를 모두 비교
- 자동 합성을 쓰려면 `NSImage`가 Equatable이 아니므로 `thumbnail`을 `Data?`(JPEG 압축 데이터)로 저장하거나, 별도 비교 필드(`thumbnailVersion: Int`)를 두는 방식 고려
- `metadataVersion` 우회 제거 가능 여부 검토

### 10. 지도 자동 fit 트리거를 "메타데이터 로딩 완료" 시점으로 이동

**현재 문제:** `PhotoMapView`가 `metadataVersion`이 처음 1이 되는 순간 fit을 잠그므로, 첫 번째 GPS 사진 한 장만 화면에 보이도록 줌인되고 그 후 도착하는 다른 위치들은 fit 대상에서 빠짐.

**수정 사항:**
- 모델에 `@Published var isLoadingMetadata: Bool`을 도입(위 #6과 함께)
- `PhotoMapView`는 `isLoadingMetadata`가 true→false로 바뀌는 시점에 한 번 `fitMapToAllPhotos()` 호출
- 추가로 헤더에 "전체 위치 보기" 버튼을 두어 사용자가 언제든 수동 fit 가능

### 11. 사이드바 즐겨찾기에도 컨텍스트 메뉴(이름 변경/삭제) 일관화 검토

**현재 문제:** `FolderLinkRow`(즐겨찾기)에는 컨텍스트 메뉴가 없고, `FolderTreeRow`에만 있음. 의도라면 OK지만 일관성을 위해 검토.

**수정 사항(둘 중 택 1):**
- 즐겨찾기도 `FolderTreeRow`로 통합하여 동일 동작 제공(트리 펼치기 + 컨텍스트 메뉴)
- 또는 즐겨찾기는 "고정된 바로가기"라는 의도라면 현재 상태 유지하고 코드 주석으로 명시

### 12. 부트 볼륨이 "장치" 섹션에 노출되는 문제

**현재 문제:** `mountedVolumeURLs(.skipHiddenVolumes)`는 `/` (Macintosh HD)도 반환하여 "장치" 섹션에 부트 디스크가 같이 표시됨.

**수정 사항(둘 중 택 1):**
- "장치"를 외장만으로 한정:
  ```swift
  .filter {
      (try? $0.resourceValues(forKeys: [.volumeIsRemovableKey]))?.volumeIsRemovable == true
  }
  ```
- 또는 "위치"(부트 볼륨)와 "외장 드라이브"로 섹션 분리

### 13. 드래그앤드롭 신뢰성 향상

**현재 문제:** `NSItemProvider(object: photo.url as NSURL)`는 대부분의 앱에서 file URL을 받지만, 일부 앱(특히 채팅/메신저)은 `kUTTypeFileURL` 또는 file promise를 명시적으로 기대.

**수정 사항:**
- `NSItemProvider`에 `registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier, ...)` 또는 `NSFilePromiseProvider`를 사용해 파일 표현 명시
- 카카오톡, Slack 등으로 실제 드래그 테스트를 추가 검증

### 14. 폴더 전환 시 Task 명시적 cancel

**현재 문제:** `loadFolder`를 빠르게 두 번 호출하면 첫 번째의 메타데이터 루프가 잠시 더 돌 수 있음. `currentFolderURL` 가드로 안전은 하지만 명시적 cancel이 더 깔끔.

**수정 사항:**
```swift
private var loadTask: Task<Void, Never>?
func loadFolder(url: URL) {
    loadTask?.cancel()
    loadTask = Task { await _loadFolder(url: url) }
}
```
- 메타데이터 루프 내에서 `Task.isCancelled` 체크 추가

---

## 작업 진행 방식 요청

1. 위 항목을 **Critical → High → Medium** 순서로 한 그룹씩 처리해 주세요.
2. 각 그룹 작업 후 다음을 보고해 주세요:
   - 수정한 파일 목록
   - 핵심 변경점(파일별 1~3줄)
   - 빌드 시 확인이 필요한 사항(권한, 설정 등)
3. 기존 코드 스타일(SwiftUI 패턴, 한국어 UI 문자열, 들여쓰기)을 유지해 주세요.
4. 새 파일 추가가 필요하면 기존 파일들과 같은 폴더(`pinframe/pinframe/`)에 만들어 주세요.
5. 빌드가 깨지지 않게 작업해 주세요. 변경 후 가능한 한 `xcodebuild` 또는 컴파일 확인을 권장합니다.
