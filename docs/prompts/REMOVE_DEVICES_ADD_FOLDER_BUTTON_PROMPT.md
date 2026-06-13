# 장치 섹션 제거 + 사진 폴더 추가 버튼 개선 — SidebarView.swift 수정 요청

## 수정 대상 파일

`pinframe/pinframe/SidebarView.swift`

---

## 현재 상태

- "장치" 섹션(`devicesTree`)이 사이드바에 표시되고 있음 — 외장 디스크를 자동 탐지해 목록에 추가
- "사진 폴더" 섹션 헤더 우측에 작은 `+` 버튼이 있음
- `devicesTree: SidebarTreeModel`, `loadVolumes()`, `mountObserver`(didMountNotification) 가 남아 있음

---

## 요구 사항

1. **"장치" 섹션 완전 제거**
2. **"장치" 섹션이 있던 자리에 "사진 폴더 추가" 버튼** 배치 (섹션 헤더의 작은 `+` 대신 더 명확한 버튼)
3. 기존 `openFolderPicker()` 로직은 그대로 유지

---

## 수정 내용

### Step 1 — 불필요한 코드 제거

다음을 **모두 삭제**:

```swift
// 삭제 1: StateObject
@StateObject private var devicesTree = SidebarTreeModel()

// 삭제 2: "장치" 섹션 블록 전체
if !devicesTree.visibleNodes.isEmpty {
    Section("장치") {
        ForEach(devicesTree.visibleNodes) { ... }
    }
}

// 삭제 3: mountObserver 선언
@State private var mountObserver: NSObjectProtocol?

// 삭제 4: onAppear 내의 loadVolumes() 호출 및 mountObserver 등록 블록
loadVolumes()
mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didMountNotification, ...
) { _ in loadVolumes() }

// 삭제 5: onDisappear 내의 mountObserver 해제 블록
if let o = mountObserver {
    NSWorkspace.shared.notificationCenter.removeObserver(o)
    mountObserver = nil
}

// 삭제 6: loadVolumes() 함수 전체
private func loadVolumes() { ... }

// 삭제 7: revealAndScroll 내의 devicesTree 호출
devicesTree.revealAncestors(of: url)
```

> **주의**: `unmountObserver`는 외장 디스크 분리 감지에 사용되므로 유지.

---

### Step 2 — "사진 폴더 추가" 버튼 배치

"장치" 섹션이 있던 위치(즐겨찾기 섹션 아래, 사진 폴더 섹션 위)에
`AddFolderButton`을 별도 섹션 없이 직접 삽입:

```swift
// 즐겨찾기 섹션 (기존 유지)
if !model.customFavorites.isEmpty {
    Section("즐겨찾기") { ... }
}

// ↓ 여기에 추가 — "장치" 섹션 자리
AddFolderButton(onTap: { openFolderPicker() })
    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)

// 사진 폴더 섹션 (헤더에서 + 버튼 제거, 텍스트만 남김)
Section("사진 폴더") {
    ForEach(locationsTree.visibleNodes) { ... }
}
```

---

### Step 3 — AddFolderButton 컴포넌트

`SidebarView.swift` 하단(또는 별도 파일)에 추가:

```swift
private struct AddFolderButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("사진 폴더 추가", systemImage: "plus.circle")
                .font(.subheadline)
                .foregroundColor(.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

---

### Step 4 — 사진 폴더 섹션 헤더 단순화

헤더에서 `+` 버튼을 제거하고 텍스트만 남김:

```swift
// 변경 전
Section {
    ...
} header: {
    HStack {
        Text("사진 폴더")
        Spacer()
        Button { openFolderPicker() } label: {
            Image(systemName: "plus").font(.caption)
        }
        .buttonStyle(.plain)
        .help("사진 폴더 추가")
    }
}

// 변경 후
Section("사진 폴더") {
    ForEach(locationsTree.visibleNodes) { ... }
}
```

---

## 최종 사이드바 구조

```
┌─────────────────────────┐
│ 즐겨찾기 (있을 때만)     │
│   • 폴더A               │
├─────────────────────────┤
│ + 사진 폴더 추가         │  ← AddFolderButton
├─────────────────────────┤
│ 사진 폴더               │
│  ∨ SynologyPhoto        │
│      ∨ 2024년           │
│        ...              │
└─────────────────────────┘
```

---

## 확인 항목

1. "장치" 섹션이 완전히 사라졌는지 (Crucial P3 등 외장 디스크가 목록에 안 나와야 함)
2. "사진 폴더 추가" 버튼 클릭 시 `NSOpenPanel`이 열리는지
3. 폴더 선택 후 "사진 폴더" 섹션 트리에 즉시 반영되는지
4. `devicesTree`, `loadVolumes`, `mountObserver` 관련 코드가 남아 있지 않은지 grep 확인:
   ```bash
   grep -n "devicesTree\|loadVolumes\|mountObserver\|didMountNotification" pinframe/pinframe/SidebarView.swift
   ```
   → 결과 없어야 함
5. `unmountObserver`는 여전히 등록되어 있어야 함 (외장 디스크 분리 감지용)
