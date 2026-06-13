# Pinframe

> A macOS photo viewer that lets you browse photos alongside a live map — see exactly where each shot was taken.

![App Icon](pinframe/Assets.xcassets/AppIcon.appiconset/pinframe_128x128.png)

---

## Screenshots

<!-- Add screenshots here after capturing them -->
<!-- Suggested captures:
     1. Full window (sidebar + photo + map)
     2. Map view with multiple pins
     3. Folder selection (first launch)
-->

---

## Features

- **Folder browser** — Add one or more root folders (including external drives); subfolders expand in the sidebar tree. Right-click a root to remove it from the list.
- **Photo viewer** — Full-resolution display with keyboard navigation (← → for photos, ↑ ↓ for sibling folders) and delete-to-trash support
- **GPS map** — Photos with location metadata appear as thumbnail pins on a MapKit map; selecting a photo moves the map to that location
- **Thumbnail strip** — Horizontal scrollable strip at the bottom for quick browsing; supports drag-out to move/copy photos
- **Copy / Move** — ⌘C / ⌘X / ⌘V to copy, cut, or paste the selected photo; drag a photo thumbnail onto any sidebar folder to trigger a copy/move confirmation dialog
- **Folder operations** — Right-click any folder in the sidebar to rename it, move it to trash, or add/remove it from Favorites
- **Favorites** — Right-click a folder → Add to Favorites; right-click a favorite → Remove from Favorites
- **Persistent session** — Remembers the last open folder across launches via Security-Scoped Bookmarks
- **External drive handling** — Alert shown when a connected drive is unmounted; bookmarks are auto-restored when the drive is reconnected
- **New folder** — Right-click any folder in the sidebar → "새 폴더 만들기" to create a subfolder; the tree updates immediately
- **Video playback** — Play iPhone (.mov) and Android (.mp4) videos in the center panel with native AVKit controls; first-frame thumbnails with a play badge appear in the strip
- **Star rating** — Rate each photo 1–5 stars in the status bar (click same star to clear); saved as Lightroom-compatible XMP `xmp:Rating` metadata — embedded for JPEG/HEIC, sidecar `.xmp` for other formats
- **Rating filter** — Multi-select exact-match filter: choose one or more star values (1–5) to show only photos with that exact rating; deselect all to restore the full list. Filter bar is always visible below the photo display.
- **Fullscreen view** — Double-click the center photo or click the icon in the top-right corner to enter full-window view; navigate with ← → arrow keys; press ESC or double-click to exit.
- **Multi-select** — ⌘+click thumbnails to toggle individual selection; Shift+click for range selection. Copy, cut, drag, or delete all selected files at once.
- **Corrupted-file handling** — 0KB or undecodable photos are excluded from the thumbnail strip; a warning alert lists the affected filenames.

## Requirements

| Item | Version |
|------|---------|
| macOS | 13 Ventura or later |
| Xcode | 15 or later |
| Swift | 5.9 or later |

## Build & Run

```bash
git clone https://github.com/your-username/pinframe.git
cd pinframe
open pinframe.xcodeproj
```

Then press **⌘R** in Xcode.

> **Note:** App Sandbox is enabled. On first launch you will be prompted to select a photo folder via the system Open Panel.

## Usage

| Action | How |
|--------|-----|
| Add photo folder | Click **Add Photo Folder** in the sidebar, or use the first-launch picker |
| Navigate photos | ← → arrow keys, or click thumbnails |
| Navigate folders | ↑ ↓ arrow keys move to the previous/next sibling folder (wraps around) |
| Delete photo | Delete key → confirm dialog (or enable "don't ask again") |
| Copy photo | ⌘C |
| Cut photo | ⌘X |
| Paste into current folder | ⌘V |
| Move / Copy via drag | Drag a thumbnail from the strip onto a sidebar folder → choose Copy or Move |
| View on map | Photos with GPS data appear as pins automatically |
| Add to favorites | Right-click a folder → Add to Favorites |
| Remove from favorites | Right-click a favorite → Remove from Favorites |
| Rename folder | Right-click a folder → Rename |
| Delete folder | Right-click a folder → Move to Trash |
| Remove root folder | Right-click a root folder → Remove from List |
| Set star rating | Click stars in the bottom status bar; click the active star again to clear |
| Filter by rating | Click one or more star numbers in the filter bar (exact match, multi-select); click **전체** to clear |
| Fullscreen view | Double-click the center photo, or click the ⤢ icon (top-right of center panel) |
| Exit fullscreen | ESC, or double-click again |

### Keyboard shortcuts at a glance

| Key | Action |
|-----|--------|
| ← | Previous photo |
| → | Next photo |
| ↑ | Previous sibling folder (same parent, alphabetical) |
| ↓ | Next sibling folder (same parent, alphabetical) |
| Delete / Forward Delete | Move current photo to Trash |
| ⌘C | Copy selected photo |
| ⌘X | Cut selected photo |
| ⌘V | Paste into current folder |
| ESC | Exit fullscreen view |

Folder navigation only considers sibling folders that contain at least one supported image (jpg, jpeg, png, heic). Folders with no photos are skipped. Arrow keys are ignored while a text field (e.g., rename dialog) is focused.

## Sharing with Friends (No Developer Account Required)

### 1. Build a Release version

In Xcode, switch to Release configuration:
```
Product → Scheme → Edit Scheme → Run → Build Configuration → Release
```

Build the app:
```
⌘ + B
```

### 2. Locate and zip the .app

```
Product → Show Build Folder in Finder
```

Open the `Release` folder, then zip `pinframe.app` from the terminal:

```bash
cd ~/Library/Developer/Xcode/DerivedData/pinframe-*/Build/Products/Release
zip -r pinframe.zip pinframe.app
```

Send `pinframe.zip` to your friend.

### 3. How your friend installs it — pick whichever is easier

macOS blocks apps from unknown developers by default (Gatekeeper). Your friend needs to override that once. Two ways:

#### Method A — One terminal command (faster, for tech-friendly friends)

1. Unzip `pinframe.zip`
2. Open Terminal and run:
   ```bash
   xattr -rd com.apple.quarantine ~/Downloads/pinframe.app
   ```
   > If the app is somewhere other than `~/Downloads/`, adjust the path.
3. Drag `pinframe.app` to `/Applications`
4. Launch from Applications or Spotlight

#### Method B — Right-click → Open (no terminal needed, for everyone else)

1. Unzip `pinframe.zip`
2. Right-click (or Control-click) `pinframe.app` → **Open**
3. In the "unidentified developer" warning, click **Open**
4. If macOS still refuses (common on Sequoia 15+):
   - Go to **System Settings → Privacy & Security**
   - Scroll down to **Security**
   - Click **Open Anyway** next to the pinframe.app notice
5. Drag `pinframe.app` to `/Applications` for permanent installation

Once approved this way, the app launches normally on subsequent double-clicks.

---

## Project Structure

```
pinframe/
├── pinframe.xcodeproj/
└── pinframe/                      # Swift source
    ├── pinframeApp.swift           # App entry point
    ├── ContentView.swift           # Root layout (3-panel HSplitView) + keyboard monitor
    ├── SidebarView.swift           # Folder tree + favorites
    ├── CenterView.swift            # Photo display + thumbnail strip
    ├── PhotoMapView.swift          # MapKit map with GPS pins
    ├── PhotoBrowserModel.swift     # Central state, photo loading, clipboard & file ops
    ├── RootFolderStore.swift       # Security-Scoped Bookmark management
    ├── DeleteConfirmDialog.swift   # Trash confirmation overlay
    ├── CopyMoveConfirmDialog.swift # Copy / Move confirmation overlay (drag-and-drop)
    ├── RatingStore.swift           # XMP rating read/write (embedded + sidecar)
    ├── AppLogger.swift             # os.Logger wrapper
    └── Assets.xcassets/
        └── AppIcon.appiconset/
```

## License

MIT License — see [LICENSE](LICENSE) for details.

---
---

# Pinframe (한국어)

> GPS 정보가 담긴 사진을 지도와 함께 감상할 수 있는 macOS 사진 뷰어입니다.

---

## 스크린샷

<!-- 스크린샷을 여기에 추가해 주세요 -->
<!-- 권장 캡처:
     1. 전체 화면 (사이드바 + 사진 + 지도)
     2. 지도에 핀이 여러 개 찍힌 화면
     3. 최초 실행 시 폴더 선택 화면
-->

---

## 주요 기능

- **폴더 탐색** — 외장 디스크를 포함한 여러 루트 폴더를 추가할 수 있으며, 하위 폴더를 사이드바 트리에서 탐색. 루트 폴더는 우클릭으로 목록에서 제거 가능
- **사진 뷰어** — 원본 해상도 표시, 키보드 탐색(← → 사진 / ↑ ↓ 형제 폴더), 휴지통 이동 지원
- **GPS 지도** — 위치 정보가 있는 사진을 MapKit 지도에 썸네일 핀으로 표시, 사진 선택 시 지도 자동 이동
- **썸네일 스트립** — 하단 가로 스크롤로 전체 사진을 빠르게 탐색; 사이드바 폴더로 드래그해 복사/이동 가능
- **복사 / 이동** — ⌘C / ⌘X / ⌘V로 선택 사진 복사·잘라내기·붙여넣기; 썸네일을 사이드바 폴더로 드래그하면 복사/이동 확인 다이얼로그 표시
- **폴더 작업** — 사이드바 폴더 우클릭으로 이름 변경, 휴지통 이동, 즐겨찾기 추가/제거 가능
- **즐겨찾기** — 폴더 우클릭 → 즐겨찾기에 추가 / 즐겨찾기에서 제거
- **세션 복원** — Security-Scoped Bookmark로 마지막 폴더를 재실행 후에도 복원
- **외장 디스크 처리** — 디스크 분리 시 알림 표시, 재연결 시 북마크 자동 복원
- **별점** — 상태바에서 사진별 1~5 별점 부여 (같은 별 재클릭 시 해제); Lightroom 호환 XMP `xmp:Rating` 메타데이터로 저장 — JPEG/HEIC는 파일 내 임베드, 기타 포맷은 `.xmp` 사이드카 생성
- **별점 필터** — 다중 선택 정확히 일치 필터: 1~5 중 하나 이상 선택 시 해당 별점 사진만 표시(이상 ❌); 전체 해제 시 전체 목록 복원. 필터 바는 항상 표시

## 요구 사항

| 항목 | 버전 |
|------|------|
| macOS | 13 Ventura 이상 |
| Xcode | 15 이상 |
| Swift | 5.9 이상 |

## 빌드 및 실행

```bash
git clone https://github.com/your-username/pinframe.git
cd pinframe
open pinframe.xcodeproj
```

Xcode에서 **⌘R** 을 누르면 빌드 및 실행됩니다.

> **참고:** App Sandbox가 활성화되어 있습니다. 최초 실행 시 사진 폴더를 직접 선택하는 화면이 나타납니다.

## 사용법

| 동작 | 방법 |
|------|------|
| 사진 폴더 추가 | 사이드바의 **사진 폴더 추가** 버튼 또는 최초 실행 화면 |
| 사진 이동 | ← → 화살표 키 또는 썸네일 클릭 |
| 폴더 이동 | ↑ ↓ 화살표 키로 이전/다음 형제 폴더 이동 (양끝에서 wrap) |
| 사진 삭제 | Delete 키 → 확인 다이얼로그 (다시 묻지 않기 옵션 있음) |
| 사진 복사 | ⌘C |
| 사진 잘라내기 | ⌘X |
| 현재 폴더에 붙여넣기 | ⌘V |
| 드래그로 이동/복사 | 썸네일을 사이드바 폴더로 드래그 → 복사/이동 선택 |
| 지도에서 위치 확인 | GPS 정보가 있는 사진은 자동으로 핀 표시 |
| 즐겨찾기 추가 | 폴더 우클릭 → 즐겨찾기에 추가 |
| 즐겨찾기 제거 | 즐겨찾기 폴더 우클릭 → 즐겨찾기에서 제거 |
| 폴더 이름 변경 | 폴더 우클릭 → 이름 변경 |
| 폴더 삭제 | 폴더 우클릭 → 휴지통으로 이동 |
| 루트 폴더 제거 | 루트 폴더 우클릭 → 이 폴더를 목록에서 제거 |
| 별점 부여 | 하단 상태바의 별 버튼 클릭; 같은 별 재클릭 시 해제 |
| 별점 필터 | 필터 바에서 숫자(1~5) 클릭 — 다중 선택, 정확히 일치; **전체** 클릭 시 초기화 |

### 키보드 단축키 요약

| 키 | 동작 |
|----|------|
| ← | 이전 사진 |
| → | 다음 사진 |
| ↑ | 이전 형제 폴더 (같은 부모, 사전순) |
| ↓ | 다음 형제 폴더 (같은 부모, 사전순) |
| Delete / Forward Delete | 현재 사진을 휴지통으로 이동 |
| ⌘C | 선택 사진 복사 |
| ⌘X | 선택 사진 잘라내기 |
| ⌘V | 현재 폴더에 붙여넣기 |

폴더 이동은 지원 이미지(jpg, jpeg, png, heic)가 1장 이상 들어 있는 형제 폴더만 대상으로 합니다. 사진이 없는 폴더는 자동으로 건너뜁니다. 이름 변경 다이얼로그 등 텍스트 입력 중에는 화살표 키가 무시되어 텍스트 커서 이동에 사용됩니다.

## 친구에게 공유하기 (Developer 계정 불필요)

### 1. Release 빌드

Xcode에서 Release 설정으로 전환:
```
Product → Scheme → Edit Scheme → Run → Build Configuration → Release
```

빌드:
```
⌘ + B
```

### 2. .app 파일 찾기 및 zip 압축

```
Product → Show Build Folder in Finder
```

`Release` 폴더에서 `pinframe.app`을 확인한 뒤, 터미널에서 zip으로 압축:

```bash
cd ~/Library/Developer/Xcode/DerivedData/pinframe-*/Build/Products/Release
zip -r pinframe.zip pinframe.app
```

`pinframe.zip`을 친구에게 전송합니다.

### 3. 친구가 설치하는 방법 — 둘 중 편한 쪽을 선택

macOS는 알 수 없는 개발자의 앱을 기본적으로 차단합니다(Gatekeeper). 친구는 처음 한 번만 이 제한을 풀어주면 됩니다. 두 가지 방법이 있습니다.

#### 방법 A — 터미널 한 줄 (빠름, 기술 친화적인 친구용)

1. `pinframe.zip` 압축 해제
2. 터미널에서 아래 명령어 실행:
   ```bash
   xattr -rd com.apple.quarantine ~/Downloads/pinframe.app
   ```
   > 앱을 `~/Downloads/`가 아닌 다른 위치에 풀었다면 경로를 그에 맞게 수정.
3. `pinframe.app`을 `/Applications` 폴더로 드래그
4. Applications 또는 Spotlight에서 실행

#### 방법 B — 우클릭 → 열기 (터미널 없이, 일반 사용자용)

1. `pinframe.zip` 압축 해제
2. `pinframe.app`을 **우클릭(또는 Control+클릭) → 열기**
3. "확인되지 않은 개발자" 경고 다이얼로그에서 **[열기]** 클릭
4. macOS가 그래도 거부하는 경우(Sequoia 15+에서 흔함):
   - **시스템 설정 → 개인정보 보호 및 보안**
   - **보안** 항목까지 스크롤
   - pinframe.app 안내 옆의 **[그래도 열기]** 클릭
5. 정상적으로 실행되면 `pinframe.app`을 `/Applications`로 드래그하여 영구 설치

한 번 허용된 앱은 이후 더블클릭만으로 정상 실행됩니다.

---

## 프로젝트 구조

```
pinframe/
├── pinframe.xcodeproj/
└── pinframe/                      # Swift 소스
    ├── pinframeApp.swift           # 앱 진입점
    ├── ContentView.swift           # 루트 레이아웃 (3패널 HSplitView) + 키보드 모니터
    ├── SidebarView.swift           # 폴더 트리 + 즐겨찾기
    ├── CenterView.swift            # 사진 표시 + 썸네일 스트립
    ├── PhotoMapView.swift          # MapKit 지도 + GPS 핀
    ├── PhotoBrowserModel.swift     # 상태 관리, 사진 로딩, 클립보드 & 파일 작업
    ├── RootFolderStore.swift       # Security-Scoped Bookmark 관리
    ├── DeleteConfirmDialog.swift   # 휴지통 이동 확인 오버레이
    ├── CopyMoveConfirmDialog.swift # 복사/이동 확인 오버레이 (드래그-앤-드롭)
    ├── RatingStore.swift           # XMP 별점 읽기/쓰기 (임베드 + 사이드카)
    ├── AppLogger.swift             # os.Logger 래퍼
    └── Assets.xcassets/
        └── AppIcon.appiconset/
```

## 라이선스

MIT License
