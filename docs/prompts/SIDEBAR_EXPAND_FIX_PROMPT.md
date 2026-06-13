# 사이드바 즐겨찾기 펼치기 문제 수정 요청

## 현상

`SidebarView.swift`의 "즐겨찾기" 섹션(홈 / 사진 / 데스크탑 / 다운로드) 옆의 `▶` 디스클로저 화살표를 클릭해도 하위 폴더 트리가 펼쳐지지 않는다. "장치"(외장 USB) 섹션의 트리는 정상 동작할 수도 있고 아닐 수도 있으니 함께 확인 필요.

## 관련 파일

- `pinframe/pinframe/SidebarView.swift`
- `pinframe/pinframe/PhotoBrowserModel.swift` (`PhotoMetadata`가 있는 파일과 동일)
- Xcode 프로젝트 빌드 설정 / `.entitlements` 파일

## 현재 구조 요약

- `SidebarView`의 "즐겨찾기" 섹션은 `ForEach(favorites)`로 `FolderTreeRow`를 만들고, `nameOverride`("홈", "사진" 등)와 `iconOverride`(SF Symbol 이름)를 전달.
- `FolderTreeRow`는 `DisclosureGroup(isExpanded: $isExpanded) { ForEach(children) { FolderTreeRow($0) } } label: { Label(displayName, systemImage: folderIcon).onTapGesture { ... }.contextMenu { ... } }` 구조.
- `.onChange(of: isExpanded) { expanded in if expanded && !isLoaded { loadChildren(); isLoaded = true } }`로 첫 펼침 시 자식 로딩.
- `loadChildren()`은 `FileManager.contentsOfDirectory(at: url, ...)`로 하위 디렉터리만 골라 `children`에 세팅.
- 빌드 설정은 `ENABLE_APP_SANDBOX = YES`, `ENABLE_USER_SELECTED_FILES = readwrite`. 별도 `.entitlements`는 아직 없을 가능성 큼.

## 의심되는 원인 (우선순위 순)

### 1. App Sandbox 권한 부족 (가장 유력)
샌드박스 앱에서 `~/`, `~/Pictures`, `~/Desktop`, `~/Downloads`는 사용자가 NSOpenPanel로 명시적으로 선택하지 않으면 `contentsOfDirectory`가 빈 배열을 반환하거나 권한 오류로 실패한다. 결과적으로 `children = []`이 되어 "펼쳐도 비어 있어서 안 펼쳐 보이는" 상태가 된다.

**검증 방법:** `loadChildren()`에 `do { try ... } catch { print("loadChildren error:", error) }`를 임시 추가하여 콘솔에 에러가 찍히는지 확인.

### 2. `List(.sidebar)` 스타일 + `DisclosureGroup` 충돌
macOS의 sidebar list 스타일은 자체적으로 outline 동작(자동 disclosure indicator)을 가질 수 있고, 그 안에 직접 `DisclosureGroup`을 두면 indicator가 표시되지 않거나 탭이 forwarded되지 않는 경우가 보고됨. "장치" 섹션의 외장 USB 트리는 동작했었다면(이전 코드 기준) 패턴이 동일하므로 이 가능성은 낮지만 확인 필요.

### 3. `label`의 `.onTapGesture { loadFolder }`가 disclosure 토글을 가로챔
`DisclosureGroup`의 label 전체에 `.contentShape(Rectangle()) + .onTapGesture`가 걸려 있어, 화살표가 아닌 라벨 영역을 클릭하면 즉시 `loadFolder`만 호출되고 펼침이 안 일어남. 사용자가 정확히 ▶ 화살표만 클릭하지 않으면 펼치기 어려움.

## 해결 요청

다음을 순서대로 처리해 주세요. **2번까지 적용 후에도 문제가 남으면 3번 진행**.

### 1. 권한(Entitlements) 추가 — 반드시 적용

`pinframe/pinframe/pinframe.entitlements` 파일을 생성(없으면)하고 아래 키를 포함:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.assets.pictures.read-write</key>
    <true/>
    <key>com.apple.security.assets.movies.read-write</key>
    <true/>
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>
</dict>
</plist>
```

그리고 `pinframe.xcodeproj/project.pbxproj`의 Debug/Release 빌드 설정에 다음을 추가:

```
CODE_SIGN_ENTITLEMENTS = pinframe/pinframe.entitlements;
```

또는 Xcode UI: Target → Signing & Capabilities → "App Sandbox" 항목에서
- File Access → User Selected File: **Read/Write**
- File Access → Pictures Folder: **Read/Write**
- File Access → Downloads Folder: **Read/Write**

를 체크.

주의: `~/` (홈 디렉터리 루트)와 `~/Desktop`은 별도 권한이 없다(Apple이 보호 폴더로 분류). 즐겨찾기 목록에서 "홈"과 "데스크탑"은 사용자가 `폴더 열기`로 한 번 선택하지 않는 한 펼침이 실패할 수밖에 없다. 대안 두 가지 중 택1:
- **(권장)** 즐겨찾기 목록에서 "홈"과 "데스크탑"을 제거하고, 대신 "사진" / "다운로드"만 남긴 뒤, 사용자가 직접 추가할 수 있는 "폴더 추가" UI를 두기 (security-scoped bookmark 저장)
- 또는 즐겨찾기 클릭 시 해당 경로에 권한이 없으면 자동으로 `NSOpenPanel`을 띄워 사용자에게 1회 권한 위임을 받은 뒤 그 bookmark를 저장

### 2. 펼치기 동작 안정화 — `loadChildren()`을 disclosure 시점 외에도 보장

현재 `.onChange(of: isExpanded)`에서만 첫 로드를 한다. 다음 두 가지를 함께 적용:

- `loadChildren()`에 에러 로깅을 추가하여 권한 오류를 가시화:
  ```swift
  private func loadChildren() {
      let fm = FileManager.default
      do {
          let contents = try fm.contentsOfDirectory(
              at: url,
              includingPropertiesForKeys: [.isDirectoryKey],
              options: .skipsHiddenFiles
          )
          children = contents.compactMap { childURL -> URL? in
              var isDir: ObjCBool = false
              fm.fileExists(atPath: childURL.path, isDirectory: &isDir)
              return isDir.boolValue ? childURL : nil
          }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      } catch {
          print("[FolderTreeRow] loadChildren failed for \(url.path): \(error)")
          children = []
      }
  }
  ```

- 권한이 없어 children이 비더라도 사용자에게 시각적으로 알리기:
  - `DisclosureGroup` content에서 `children.isEmpty && isLoaded`면 `Text("접근 권한이 없거나 비어 있음").font(.caption).foregroundColor(.secondary)` 표시.

### 3. (2번까지 했는데도 안 펼쳐지면) `DisclosureGroup` 대신 `OutlineGroup` 또는 수동 disclosure 버튼

macOS `List(.sidebar)` + `DisclosureGroup` 조합이 의도대로 동작하지 않을 가능성이 있음. 다음 중 하나로 교체:

**대안 A — `OutlineGroup` 사용 (sidebar에 최적):**

`FolderNode` 같은 트리 모델을 만들어 `OutlineGroup(rootNodes, children: \.children)`로 표현. lazy 로딩이 까다로워 권장도는 낮음.

**대안 B — 명시적 disclosure 버튼 + 라벨 분리 (권장):**

`DisclosureGroup`을 쓰지 않고 수동으로 펼침 상태를 그리는 방식. `▶` 버튼과 라벨의 hit area를 분리해서, 화살표만 펼침/접힘에 반응하고 라벨 탭은 폴더 선택만 한다.

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 4) {
            Button {
                isExpanded.toggle()
                if isExpanded && !isLoaded { loadChildren(); isLoaded = true }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Label(displayName, systemImage: folderIcon)
                .foregroundColor(isSelected ? .accentColor : .primary)
                .fontWeight(isSelected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await model.loadFolder(url: url) }
                }
                .contextMenu { /* 기존 이름변경/삭제 */ }
        }

        if isExpanded {
            ForEach(children, id: \.self) { child in
                FolderTreeRow(url: child, model: model)
                    .padding(.leading, 16)
            }
        }
    }
    .onReceive(model.folderChanged) { changedParent in
        if changedParent == url { loadChildren() }
    }
    // 기존 alert들 그대로
}
```

이 패턴은 List 스타일과 무관하게 작동하므로 가장 안정적이다.

## 작업 후 확인 항목

1. Xcode 콘솔에 `loadChildren failed for ...` 로그가 보이는지 확인. 보이면 권한 문제이므로 1번 entitlements가 제대로 적용됐는지 재확인.
2. 권한이 있는 폴더(사진, 다운로드, 사용자가 NSOpenPanel로 선택한 폴더)의 ▶을 누르면 하위 폴더가 표시되는지.
3. 펼친 폴더 안에서 라벨을 클릭하면 그 폴더가 가운데 사진 영역에 로드되는지 (loadFolder 호출).
4. 텍스트 입력(이름 변경) 중에는 좌/우 화살표 키가 정상적으로 텍스트 커서 이동에 쓰이는지(글로벌 키 모니터의 NSTextView 가드 확인).
5. 외장 USB("장치" 섹션)의 트리는 변경 후에도 그대로 펼쳐지는지 회귀 테스트.

## 보고 양식

- 어느 원인이었는지 (1/2/3 중)
- 수정한 파일 목록과 각 파일별 핵심 변경점
- entitlements 파일을 새로 만들었다면 그 경로
- 빌드 후 콘솔 로그 캡처 (가능하면)
