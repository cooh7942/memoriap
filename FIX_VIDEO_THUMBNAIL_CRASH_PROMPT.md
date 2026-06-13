# 버그 수정 — 폴더 로드 시 동영상 썸네일 생성으로 앱 크래시

## 확정된 원인 (크래시 로그 분석)

크래시 로그를 분석한 결과 아래 세 가지 문제가 연쇄적으로 발생한다.

1. `PhotoBrowserModel.swift:692`의 `loadPhotos` 안 `withTaskGroup`이 폴더의 **모든 파일을 한꺼번에** `addTask`에 등록한다.
2. 동영상이 많으면 `AVAssetImageGenerator`가 **수십 개 동시 생성**되어 MediaToolbox / AudioToolbox 스레드 풀이 포화된다.
3. 그 와중에 메인 스레드에서 `_AVKit_SwiftUI`의 `VideoPlayer` 뷰 초기화가 실패(`swift::fatalError`) → `abort()`.

**근본 원인:** 동영상 썸네일 생성(`AVAssetImageGenerator.copyCGImage(at:actualTime:)`)을 동시에 너무 많이 실행하는 것.

---

## 수정 목표

1. 썸네일/메타데이터 로딩의 **동시 실행 개수를 3개로 제한**한다.
2. 동영상 썸네일 생성을 **비동기 API + 안전 실패**로 바꿔 파일 하나가 멈춰도 앱이 죽지 않게 한다.
3. (옵션) 위 두 가지 적용 후에도 `VideoPlayer` 크래시가 재현되면 AppKit `AVPlayerView`로 교체한다.

코드 수정 후 **사용자 리뷰를 기다린다**. 커밋·푸시·브랜치 작업은 사용자가 직접 처리하므로 수행하지 않는다.

---

## 수정 1 — 슬라이딩 윈도우로 동시 실행 제한 (`PhotoBrowserModel.swift`)

`loadPhotos`에서 `metadataTask` 블록 내부의 `withTaskGroup` 구현을 아래 구조로 교체한다. **기존 `flush` 함수의 내부 구현(MainActor 배치 업데이트 로직)은 그대로 유지**하고, 루프 구조만 슬라이딩 윈도우 방식으로 바꾼다.

```swift
metadataTask = Task.detached(priority: .userInitiated) { [weak self] in
    let maxConcurrent = 3   // 동시 생성 상한 (동영상 포화 방지)
    await withTaskGroup(of: (Int, NSImage?, CLLocationCoordinate2D?, Int).self) { group in

        func makeTask(_ i: Int) {
            let url = urls[i]
            group.addTask {
                guard !Task.isCancelled else { return (i, nil, nil, 0) }
                let ext = url.pathExtension.lowercased()
                let isVideo = ["mov", "mp4", "m4v"].contains(ext)
                let thumb = isVideo
                    ? await PhotoMetadata.loadVideoThumbnail(from: url)
                    : PhotoMetadata.loadThumbnail(from: url)
                let coord = isVideo ? nil : PhotoMetadata.extractGPS(from: url)
                let rating = isVideo ? 0 : RatingStore.readRating(from: url)
                return (i, thumb, coord, rating)
            }
        }

        var next = 0
        let count = urls.count
        while next < min(maxConcurrent, count) { makeTask(next); next += 1 }

        let batchSize = 20
        var pending: [(Int, NSImage?, CLLocationCoordinate2D?, Int)] = []
        pending.reserveCapacity(batchSize)
        var done = 0

        // flush 내부 구현은 기존 것 그대로 유지

        while let result = await group.next() {
            pending.append(result)
            done += 1
            if pending.count >= batchSize { await flush(done) }
            if next < count {   // 하나 끝나면 다음 1개 투입 → 동시 개수 일정 유지
                makeTask(next); next += 1
            }
        }
        await flush(done)
        await MainActor.run { [weak self] in self?.isLoadingMetadata = false }
    }
}
```

핵심: `makeTask`를 처음 `maxConcurrent`개만 등록하고, `group.next()` 루프 안에서 하나가 끝날 때마다 다음 1개를 추가 투입한다.

---

## 수정 2 — 비동기 썸네일 API + 안전 실패 (`PhotoMetadata.swift`)

`loadVideoThumbnail`을 `async` 함수로 바꾸고, 동기 `copyCGImage(at:actualTime:)` 대신 macOS 13+의 비동기 `image(at:)` API를 사용한다. 실패는 `nil` 반환으로 처리해 크래시를 방지한다.

기존 `static func loadVideoThumbnail(from url: URL) -> NSImage?` 시그니처를 아래로 교체한다.

```swift
nonisolated static func loadVideoThumbnail(from url: URL) async -> NSImage? {
    if let cached = thumbnailCache.object(forKey: url as NSURL) { return cached }

    let asset = AVURLAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 300, height: 300)
    gen.requestedTimeToleranceBefore = .positiveInfinity   // 가까운 키프레임 사용 → 빠르고 안정적
    gen.requestedTimeToleranceAfter  = .positiveInfinity
    let time = CMTime(seconds: 1, preferredTimescale: 600)

    do {
        let cg: CGImage = try await gen.image(at: time).image   // macOS 13+
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnailCache.setObject(image, forKey: url as NSURL)
        return image
    } catch {
        Logger.video.error("video thumbnail 실패: \(url.lastPathComponent, privacy: .public) - \(error.localizedDescription, privacy: .public)")
        return nil
    }
}
```

`loadVideoThumbnail`이 `async`가 되면 수정 1의 `makeTask` 안 호출부도 이미 `await`로 반영되어 있다. 별도 수정 불필요.

---

## 수정 3 (옵션) — `VideoPlayer` 크래시가 계속되면 AppKit으로 교체

수정 1·2 적용 후 검증 항목 1번을 테스트했을 때 여전히 `_AVKit_SwiftUI` 크래시가 재현되는 경우에만 이 수정을 적용한다.

`VideoPlayerView.swift` (또는 동영상 재생 뷰가 있는 파일)에 아래 타입을 추가한다.

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
        if v.player !== player { v.player = player }
    }
}
```

그런 다음 동영상 재생 뷰 내부의 `VideoPlayer(player: player)` 호출을 `PlayerViewRepresentable(player: player)`로 교체한다.

---

## README.md 수정

README의 **Video playback** 기능 설명 항목(영문/한국어 양쪽)에 아래 내용을 추가한다.

- 영문: `; concurrent thumbnail generation is rate-limited to prevent resource exhaustion with large video folders`
- 한국어: `; 동영상이 많은 폴더에서도 썸네일 동시 생성 수를 제한해 안정적으로 동작`

---

## 확인 항목

수정이 끝나면 아래 항목을 직접 확인하고 결과를 보고한다.

1. **핵심 검증:** 동영상 10개 이상인 폴더를 열었을 때 크래시 없이 썸네일이 점진적으로 채워지는지.
2. **동시 개수 확인:** 로그 또는 Instruments에서 동시에 실행 중인 `AVAssetImageGenerator`가 `maxConcurrent`(3) 이하로 유지되는지.
3. **안전 실패:** 손상됐거나 코덱 미지원 동영상이 포함된 폴더에서 앱이 죽지 않고 해당 항목만 placeholder로 표시되는지.
4. **재생 정상 동작:** 동영상을 선택했을 때 센터 패널 재생 및 전체 화면이 정상 동작하는지.
5. **혼합 폴더:** 사진+동영상 혼합 폴더에서 ← → 탐색과 썸네일 스크롤이 매끄러운지.
6. **로그 정돈:** 수정 과정에서 추가된 임시 `print` 또는 과도한 로그가 없는지, 남기는 로그는 `.debug` / `.error` 수준으로 정돈됐는지.

---

## 작업 후 보고 양식

```
## 수정 결과

### 수정한 파일
- PhotoBrowserModel.swift — 슬라이딩 윈도우 적용 (변경 전/후 핵심 라인 요약)
- PhotoMetadata.swift — loadVideoThumbnail async 전환 (변경 전/후 시그니처)
- (옵션) VideoPlayerView.swift — PlayerViewRepresentable 교체 여부
- README.md — 설명 추가 여부

### 확인 항목 결과
1. 동영상 10개 이상 폴더 크래시 여부:
2. 동시 AVAssetImageGenerator 개수 확인 결과:
3. 손상 파일 안전 실패 확인:
4. 동영상 재생 정상 동작 확인:
5. 혼합 폴더 탐색 확인:
6. 로그 정돈 완료 여부:

### 특이 사항 / 추가 발견된 문제
(없으면 "없음")
```
