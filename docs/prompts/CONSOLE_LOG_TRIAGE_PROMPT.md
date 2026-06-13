# 콘솔 로그 트리아지 및 수정 요청

## 발견된 콘솔 로그

```
Failed to locate resource named "default.csv"
CAMetalLayer ignoring invalid setDrawableSize width=0.000000 height=0.000000
networkd_settings_read_from_file Sandbox is preventing this process from reading networkd settings file at "/Library/Preferences/com.apple.networkd.plist", please add an exception.
networkd_settings_read_from_file Sandbox is preventing this process from reading networkd settings file at "/Library/Preferences/com.apple.networkd.plist", please add an exception.
```

## 먼저 확인할 것 — 앞선 Sandbox 권한 이슈와의 관련성

위 로그들은 **`SANDBOX_PERMISSION_FIX_PROMPT.md`에서 다루는 폴더 접근 권한 문제와는 별개**다. 즉, 사용자 폴더(`~/Pictures` 등)에 접근하지 못하는 증상의 원인은 위 로그가 아니므로 혼동하지 말 것. 별도로 분류해서 처리:

- **Apple 시스템 프레임워크 내부 노이즈 (수정 불가/무해)**: 첫 번째와 세 번째(networkd) 메시지
- **앱 측에서 완화 가능한 항목**: 두 번째 CAMetalLayer 메시지

각각을 아래 지침대로 처리한 뒤, 결과를 보고할 것.

---

## 1. `Failed to locate resource named "default.csv"`

**진단:** MapKit / CoreLocation 또는 그 하위 프레임워크(GeoServices, VectorKit 등)가 내부적으로 찾는 데이터 파일. 시스템 프레임워크의 내부 동작 로그이며 앱 동작에는 영향 없음. macOS 26 미만/이상에서 `Map` 또는 `CLLocationManager`를 쓰는 거의 모든 앱에서 출력됨.

**조치:**
- **코드 수정 불필요.** 앱 측에서 해결할 방법 없음.
- Apple 프레임워크 내부 로그라는 사실을 코드 주석 등으로 남길 필요도 없음.
- 사용자에게 "이건 시스템 프레임워크 내부 로그이며 무시해도 됨"이라고 설명.

---

## 2. `CAMetalLayer ignoring invalid setDrawableSize width=0.000000 height=0.000000`

**진단:** Metal로 렌더링되는 뷰(여기서는 SwiftUI `Map`)가 레이아웃 중 한 프레임이라도 0×0 크기를 받았을 때 출력됨. **기능적 문제는 거의 없지만**, `PhotoMapView`의 조건부 렌더링 구조가 원인일 가능성이 높음.

**현재 `pinframe/pinframe/PhotoMapView.swift` 의심 부분:**

```swift
if photosWithCoords.isEmpty {
    // 빈 상태 placeholder
} else {
    Map(position: $cameraPosition) { ... }
}
```

이 패턴에서 `photosWithCoords`가 빈 → 값이 들어옴으로 토글될 때 `Map`이 새로 만들어지면서 첫 레이아웃 패스에 0×0을 받을 수 있음.

**조치:**

### (A) Map을 항상 그리되 비어 있을 때만 placeholder를 오버레이로 덮기 — 권장

`PhotoMapView`의 body를 다음 패턴으로 변경:

```swift
ZStack {
    Map(position: $cameraPosition) {
        ForEach(photosWithCoords) { photo in
            if let coord = photo.coordinate {
                Annotation("", coordinate: coord, anchor: .bottom) {
                    PhotoPinView(photo: photo, isSelected: model.selectedPhoto?.id == photo.id)
                        .onTapGesture { ... }
                }
            }
        }
    }
    .onChange(of: model.metadataVersion) { ... }
    .onChange(of: model.currentFolderURL) { ... }
    .onChange(of: model.selectedPhoto?.id) { ... }

    if photosWithCoords.isEmpty {
        VStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("GPS 정보가 있는\n사진이 없습니다")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

이렇게 하면 Map이 항상 같은 컨테이너에 살아 있어서 사이즈가 0이 되는 순간이 없어짐.

### (B) 최소 사이즈 보장

`PhotoMapView`의 컨테이너에 `.frame(minWidth: 1, minHeight: 1)`을 명시. 단 (A)가 더 근본적인 해결책이므로 우선 (A) 적용 후 효과 없을 때만 (B) 추가.

### (C) 그래도 남으면 무시

위 두 가지를 적용해도 한두 줄은 계속 찍힐 수 있음. SwiftUI/MapKit의 초기 렌더 패스에서 발생하는 known harmless log임. 더 이상 코드로 통제 불가.

---

## 3. `networkd_settings_read_from_file Sandbox is preventing ... com.apple.networkd.plist`

**진단:** macOS의 네트워크 데몬(`networkd`)이 시스템 환경설정 파일을 읽으려다 샌드박스 제약으로 거부당한다는 **시스템 내부 로그**. 우리 앱이 직접 그 파일을 읽으려 한 게 아니라, Apple 프레임워크(주로 MapKit 타일 다운로드, CoreLocation, URLSession 등)가 내부적으로 시도. 메시지는 "please add an exception"이라고 하지만 **앱이 직접 추가할 수 있는 entitlement도 없고, 추가해서도 안 됨**. 실제 네트워크 동작에는 영향 없음.

**조치:**
- **코드 수정 불필요.** entitlements에 임의로 추가하면 코드 사인이 깨지거나 App Store 심사에서 거부됨.
- macOS 시스템 프레임워크의 알려진 노이즈로 분류.

---

## Xcode 콘솔이 너무 시끄러울 때 — 로그 필터링 권장 사항

위 세 메시지는 모두 시스템 노이즈라 디버깅에 방해됨. Xcode 콘솔 하단의 필터 검색창에 아래 표현 중 하나를 입력해 노이즈를 숨길 수 있음.

**제외 검색(텍스트 앞에 `!` 또는 "Hide" 옵션):**
- `default.csv`
- `CAMetalLayer`
- `networkd_settings`

또는 콘솔 검색창 우측 톱니바퀴 → "Subsystem" 필터로 자기 앱의 subsystem만 표시.

더 깔끔하게 하려면 앱에서 `os.Logger`를 도입하고 자기 subsystem(`cooh.pinframe`)으로만 로그를 남긴 뒤, Xcode 콘솔에서 해당 subsystem만 필터:

```swift
import os

extension Logger {
    static let app = Logger(subsystem: "cooh.pinframe", category: "app")
    static let photos = Logger(subsystem: "cooh.pinframe", category: "photos")
    static let map = Logger(subsystem: "cooh.pinframe", category: "map")
}

// 사용
Logger.photos.error("loadChildren failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
```

이러면 콘솔에서 `subsystem:cooh.pinframe`으로 필터링하면 자기 로그만 보임.

---

## 작업 후 보고 양식

1. **세 로그 각각의 분류:**
   - default.csv → 시스템 노이즈, 무수정
   - CAMetalLayer → 코드 수정 적용 여부 / 적용 후에도 남는지
   - networkd → 시스템 노이즈, 무수정
2. **PhotoMapView.swift 수정 여부와 핵심 변경점**
3. **수정 후 콘솔에 CAMetalLayer 로그가 사라졌는지 / 줄었는지 / 동일한지**
4. **앞선 Sandbox 권한 이슈(`~/Pictures` 접근 거부)와 위 로그들은 무관함을 확인했다는 한 줄 문장**
