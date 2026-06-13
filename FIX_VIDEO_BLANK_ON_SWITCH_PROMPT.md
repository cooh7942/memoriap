# 버그 수정 — 연속 동영상 전환 시 소리만 나고 영상이 안 보임

## 증상
동영상이 연속으로 있을 때 두 번째 동영상을 선택하면 **가끔 소리만 나고 화면은 검게/멈춤** 상태가 된다.
세 번째 동영상으로 갔다가 다시 두 번째로 돌아오면 정상 재생된다.

## 원인
`CenterView.swift`의 `VideoPlayerView`가 `.task(id: url)` 안에서 매번 **새 `AVPlayer` 인스턴스로 교체**한다.
하지만 동영상 → 동영상으로 전환할 때 SwiftUI는 같은 위치의 `VideoPlayer` 뷰를 **재사용**하므로,
플레이어 참조는 바뀌었는데 내부 비디오 레이어가 새 플레이어에 다시 연결되지 않아 **오디오만 재생**된다.
(다른 항목으로 갔다 오면 뷰가 해제·재생성되어 레이어가 새로 붙어 정상화된다.)

## 수정 방침
동영상마다 재생 뷰가 **확실히 새 인스턴스로 다시 그려지도록** 한다. 아래 1번(최소 수정)을 적용하고,
그래도 재현되면 2번(AppKit 플레이어)으로 교체한다.

> Git(브랜치/커밋/푸시)은 사용자가 직접 처리한다. 코드 수정 후 **사용자 리뷰**를 기다린다.

---

## 수정 1 (우선) — URL별로 재생 뷰에 고유 identity 부여

`VideoPlayerView`를 호출하는 **두 곳 모두**에 `.id(photo.url)`를 붙여, 동영상이 바뀌면 SwiftUI가 뷰를
재사용하지 않고 새로 생성하도록 강제한다.

`CenterView.swift`의 두 호출부(센터 패널 ~35행, 전체 화면 ~422행):

```swift
// 변경 전
VideoPlayerView(url: photo.url)

// 변경 후
VideoPlayerView(url: photo.url)
    .id(photo.url)        // 동영상이 바뀌면 뷰를 새로 생성 → 비디오 레이어 새로 연결
```

`.id(url)`가 붙으면 `VideoPlayerView`는 URL이 바뀔 때마다 완전히 새로 만들어지므로,
내부 `@State player`·비디오 레이어가 깨끗하게 재생성된다.

> 참고: 이렇게 하면 `VideoPlayerView` 내부의 `.task(id: url)`/`onDisappear` 정리 로직은 그대로 둬도 된다
> (뷰 재생성 시 onDisappear로 이전 플레이어가 pause·해제되고 security-scoped 접근도 정상 해제됨).

---

## 수정 2 (수정 1로도 재현되면) — SwiftUI `VideoPlayer` → AppKit `AVPlayerView`

SwiftUI `VideoPlayer`는 재사용 시 레이어 갱신이 불안정하다. AppKit `AVPlayerView`로 바꾸면 이 류의 버그가 사라진다.

`CenterView.swift`(또는 별도 파일)에 추가:

```swift
import AVKit

struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }   // 플레이어 교체 시 레이어 갱신
    }
}
```

`VideoPlayerView.body`의 `VideoPlayer(player: player)`를 `PlayerViewRepresentable(player: player)`로 교체한다.
(`.onAppear { player.play() }`는 유지.)

> 수정 2를 적용하면 수정 1의 `.id(photo.url)`는 없어도 되지만, 함께 둬도 무방하다.

---

## 확인 항목

1. 동영상이 3개 이상 연속으로 있는 폴더에서 **두 번째 동영상을 여러 번 선택**해도 매번 영상이 정상 표시되는지.
2. 동영상 ↔ 동영상, 사진 ↔ 동영상 전환을 반복해도 소리만 나거나 멈추는 현상이 없는지.
3. 전체 화면에서도 동일하게 정상 재생되는지.
4. 전환 시 이전 동영상의 소리가 끊기고(중복 재생 없음), 메모리 누수가 없는지.
5. 동영상에서 다른 폴더로 이동했다가 돌아와도 정상인지.

---

## 작업 후 보고 양식

```
## 수정 결과
### 수정한 파일
- CenterView.swift — (수정 1) .id(photo.url) 추가 위치 / (수정 2 적용 시) PlayerViewRepresentable 교체 여부
### 확인 항목 결과
1. 두 번째 동영상 반복 선택:
2. 전환 반복:
3. 전체 화면:
4. 소리 중복/누수:
5. 폴더 이동 후 복귀:
### 적용한 수정: 1번만 / 1번+2번
```
