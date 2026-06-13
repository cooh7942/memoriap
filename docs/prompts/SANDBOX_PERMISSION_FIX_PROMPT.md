# Sandbox 권한 적용 불일치 이슈 — 진단/수정 요청

## 현상

Xcode의 Target → Signing & Capabilities → App Sandbox → File Access 항목에서 다음을 모두 **Read/Write**로 설정했음에도, 앱 실행 시 폴더 접근이 거부됨("권한 없음" 에러, `contentsOfDirectory` 실패, 또는 사이드바 트리 펼치기 실패).

- User Selected File: Read/Write
- Pictures Folder: Read/Write
- Downloads Folder: Read/Write
- (필요 시) Music / Movies Folder: Read/Write

## 검토 대상 파일

- `pinframe.xcodeproj/project.pbxproj`
- `pinframe/pinframe.entitlements` (또는 다른 이름으로 존재할 수 있음 — 프로젝트 루트 검색 필요)
- `pinframe/pinframe/PhotoBrowserModel.swift` (security-scoped bookmark 복원 로직)
- `pinframe/pinframe/SidebarView.swift` (즐겨찾기 클릭 시 loadFolder 호출 부분)

## 의심되는 원인 (우선순위 순)

### 1. entitlements 파일이 실제로 빌드에 포함되지 않음
Xcode UI에서 체크해도 다음 중 하나라면 적용되지 않음:
- `.entitlements` 파일이 디스크에는 있지만 `CODE_SIGN_ENTITLEMENTS` 빌드 설정이 비어 있거나 잘못된 경로
- `.entitlements` 파일이 Target의 "Copy Bundle Resources"에는 포함되어 있지만 code sign에는 연결되지 않음
- 두 개 이상의 `.entitlements` 파일이 있고 다른 파일이 사용되고 있음

### 2. 빌드 설정 충돌 (`ENABLE_USER_SELECTED_FILES`가 readonly로 남음)
프로젝트 초기 설정 시 `ENABLE_USER_SELECTED_FILES = readonly`가 들어가 있었고, Xcode UI에서 권한 박스를 다시 체크해도 이 설정이 그대로 남아 있으면 entitlements와 충돌해 readonly로 동작.

### 3. macOS의 TCC(Transparency, Consent, Control) 미허용
entitlement은 "내가 이 폴더에 접근하고 싶다"는 선언일 뿐, 실제 접근은 macOS의 TCC가 별도로 통제. 첫 접근 시 시스템 다이얼로그가 떠야 하는데, 시그니처/번들 ID가 바뀐 경우 다이얼로그 없이 무조건 거부될 수 있음.

### 4. 샌드박스 컨테이너에 남은 stale 권한
이전 실행에서 받은 `security-scoped bookmark`가 `UserDefaults`에 남아 있고, `restoreLastFolder()`가 그걸 복원하려다가 stale/invalid 상태로 실패. 또는 컨테이너 자체가 손상.
경로: `~/Library/Containers/cooh.pinframe/`

### 5. 진입 불가 경로(`~/`, `~/Desktop`)에 entitlement이 없음
Apple은 홈 루트(`~/`)와 데스크탑(`~/Desktop`)에 대해 별도의 단순 entitlement을 제공하지 않음. `assets.pictures.read-write` 같은 키가 존재하지 않는 경로에 대해 권한 박스만 켰다고 동작하지 않음. 이 경로들은 **NSOpenPanel을 통한 사용자 명시 선택**만 가능.

### 6. 코드사인 이슈 (Hardened Runtime / 개발자 ID 변경)
- 개인 Apple ID로 자동 서명 중인데 키체인이 꼬여서 entitlements가 적용되지 않음
- "Sign to Run Locally" 모드일 때 일부 entitlement이 무시될 수 있음

## 진단 단계 — 순서대로 수행

### Step 1: 현재 빌드 설정 / entitlements 실태 확인

다음 명령으로 실제 빌드 설정을 덤프하고 결과를 제시:

```bash
cd /Users/cooh/Documents/Project/pinframe
grep -nE "CODE_SIGN_ENTITLEMENTS|ENABLE_USER_SELECTED_FILES|ENABLE_APP_SANDBOX|PRODUCT_BUNDLE_IDENTIFIER" pinframe.xcodeproj/project.pbxproj
find . -name "*.entitlements" -type f
```

빌드 후 실제 앱 번들에 들어간 entitlements를 직접 추출(가장 확실한 방법):

```bash
# DerivedData 위치 확인
DERIVED=$(xcodebuild -project pinframe.xcodeproj -showBuildSettings 2>/dev/null | grep -m1 "CONFIGURATION_BUILD_DIR" | awk -F'= ' '{print $2}')
echo "Build dir: $DERIVED"

# 또는 archive 후
APP="$DERIVED/pinframe.app"
codesign -d --entitlements :- "$APP" 2>/dev/null
```

이 출력에 다음 키들이 `<true/>`로 보여야 함:
- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.assets.pictures.read-write`
- `com.apple.security.files.downloads.read-write` ⚠️ (Downloads는 `assets`가 아니라 `files` 네임스페이스)

보이지 않으면 원인 1 또는 2.

### Step 2: entitlements 키 이름이 정확한지 검증

자주 헷갈리는 키들 (Apple 문서 기준 정확한 이름):

| 폴더 | 정확한 키 |
|------|----------|
| 사용자 선택 파일 (Read/Write) | `com.apple.security.files.user-selected.read-write` |
| Pictures | `com.apple.security.assets.pictures.read-write` |
| Music | `com.apple.security.assets.music.read-write` |
| Movies | `com.apple.security.assets.movies.read-write` |
| Downloads | `com.apple.security.files.downloads.read-write` ⚠️ `assets`가 아님 |
| Documents | `com.apple.security.files.documents.read-write` |
| 홈 디렉터리 루트(`~/`) | **없음** — NSOpenPanel만 가능 |
| Desktop(`~/Desktop`) | **없음** — NSOpenPanel만 가능 |

`pinframe/pinframe.entitlements`(혹은 발견된 파일)를 열어 위 키와 정확히 일치하는지 확인하고, 오타가 있다면 수정.

### Step 3: 빌드 설정 충돌 제거

`pinframe.xcodeproj/project.pbxproj`에서 다음을 검색:

```
ENABLE_USER_SELECTED_FILES = readonly;
```

이 줄이 남아 있으면 **모두 삭제**(또는 `= readwrite;`로 변경). Debug/Release 둘 다 확인.

`CODE_SIGN_ENTITLEMENTS`가 비어 있으면 Debug/Release 양쪽에 다음을 추가:

```
CODE_SIGN_ENTITLEMENTS = pinframe/pinframe.entitlements;
```

(실제 entitlements 파일 경로에 맞게 조정)

### Step 4: 클린 빌드 + 컨테이너/DerivedData 초기화

```bash
# 1. 앱 삭제
rm -rf ~/Applications/pinframe.app 2>/dev/null
rm -rf "/Applications/pinframe.app" 2>/dev/null

# 2. 샌드박스 컨테이너 삭제 (stale bookmark/권한 제거)
rm -rf ~/Library/Containers/cooh.pinframe

# 3. DerivedData 클린
rm -rf ~/Library/Developer/Xcode/DerivedData/pinframe-*

# 4. Xcode에서 Product → Clean Build Folder (⌥⇧⌘K) 후 재빌드
```

다시 실행했을 때 macOS가 "pinframe에서 Pictures 폴더에 접근하려고 합니다" 같은 시스템 다이얼로그를 띄우는지 확인. 다이얼로그가 안 뜨면 entitlements 자체가 적용 안 된 것(Step 1로 돌아가서 codesign 출력 재확인).

### Step 5: 어느 경로에서 실패하는지 정확히 로깅

`SidebarView.swift`의 `loadChildren()`(또는 `loadFolder` 흐름)에 다음 로그 추가:

```swift
private func loadChildren() {
    let fm = FileManager.default
    do {
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        print("[FolderTreeRow] OK: \(url.path) -> \(contents.count) items")
        children = contents.compactMap { ... }.sorted { ... }
    } catch {
        let ns = error as NSError
        print("[FolderTreeRow] FAIL: \(url.path)")
        print("  domain=\(ns.domain) code=\(ns.code)")
        print("  desc=\(ns.localizedDescription)")
        children = []
    }
}
```

콘솔에서:
- `NSCocoaErrorDomain code=257` → 권한 없음(Operation not permitted) → entitlement 미적용 또는 TCC 거부
- `NSCocoaErrorDomain code=260` → 경로 없음(파일/폴더 없음, 권한과 무관)
- `NSPOSIXErrorDomain code=1` (EPERM) → 시스템 차원에서 막힘

어느 경로(`~/Pictures`인지 `~/`인지)가 실패하는지 사용자에게 보고.

### Step 6: 진입 불가 경로 처리

`~/`(홈)와 `~/Desktop`은 entitlement으로 못 풂. 사이드바 즐겨찾기에서 다음 중 하나로 처리:

- **(권장)** 즐겨찾기 기본 목록에서 "홈"과 "데스크탑" 제거. 대신 "폴더 추가" 버튼으로 사용자가 NSOpenPanel을 통해 직접 추가하고 security-scoped bookmark로 저장.
- 또는 클릭 시 권한이 없으면 자동으로 `NSOpenPanel`을 띄워 1회 권한 위임을 받은 뒤 bookmark 저장.

`SidebarView.swift`의 favorites 정의에서 "홈"/"데스크탑" 항목을 제거하거나, 클릭 시 권한 확인 후 NSOpenPanel을 띄우는 분기 추가.

### Step 7: stale bookmark 방어 코드

`PhotoBrowserModel.restoreLastFolder()`에서 bookmark 복원이 실패해도 앱 시작이 막히지 않도록 명확한 try/catch + 실패 시 bookmark 삭제 후 fresh start:

```swift
private func restoreLastFolder() async {
    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
    var isStale = false
    do {
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            print("[restoreLastFolder] startAccessing failed; clearing bookmark")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return
        }
        securityScopedURL = url
        if isStale { saveBookmark(for: url) }
        currentFolderURL = url
        await loadPhotos(from: url)
    } catch {
        print("[restoreLastFolder] resolve failed: \(error); clearing bookmark")
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
}
```

## 작업 후 확인 항목

1. `codesign -d --entitlements :- /path/to/pinframe.app` 출력에 다음 모두 `true`로 표시:
   - `com.apple.security.app-sandbox`
   - `com.apple.security.files.user-selected.read-write`
   - `com.apple.security.assets.pictures.read-write`
   - `com.apple.security.files.downloads.read-write`
2. 컨테이너 삭제 후 첫 실행 시 macOS 시스템 권한 다이얼로그가 뜨고, 허용 후 정상 접근.
3. 콘솔에 `[FolderTreeRow] OK: /Users/cooh/Pictures -> N items` 로그 확인.
4. NSOpenPanel로 외부 폴더(예: 외장 USB)를 선택하면 정상 접근, 앱 재실행 후 bookmark로 복원되어 동일 폴더 자동 로드.
5. "홈"/"데스크탑"은 권한 정책상 직접 진입 불가 — UI에서 제거되었거나, 클릭 시 NSOpenPanel이 자동 호출되는지 확인.

## 보고 양식

- Step 1의 `grep` / `codesign -d` 출력 결과
- entitlements 파일의 실제 위치와 내용
- 어느 키가 빠져 있었거나 어떤 빌드 설정이 충돌했는지
- Step 4 클린 후 macOS 권한 다이얼로그가 떴는지 여부
- Step 5 로그에서 실제로 실패하는 경로와 에러 코드
- 최종 수정한 파일 목록과 변경점 요약
