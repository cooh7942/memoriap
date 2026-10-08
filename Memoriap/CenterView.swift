import SwiftUI
import AVKit
import os

struct CenterView: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        PhotoDisplayArea(model: model)
    }
}

// MARK: - Main photo display

struct PhotoDisplayArea: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.1)

            if model.selectedIDs.count > 1 {
                StackedPhotosView(photos: model.selectedPhotosInOrder, topID: model.selectedPhoto?.id)
            } else if let photo = model.selectedPhoto {
                Group {
                    if photo.isVideo {
                        let _ = Logger.video.debug("display video: \(photo.name, privacy: .public)")
                        VideoPlayerView(url: photo.url)
                            .id(photo.url)
                    } else {
                        PhotoImageView(photo: photo, allowsDragOut: true)
                    }
                }
                .onTapGesture(count: 2) { model.enterFullScreen() }
            } else if !model.isLoadingFiles {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text(model.currentFolderURL == nil ? "좌측에서 폴더를 선택하세요" : "이 폴더에 사진이 없습니다")
                        .foregroundColor(.secondary)
                }
            }

            // 폴더 스캔 중 로딩 표시 — 콘텐츠 위에 항상 오버레이
            if model.isLoadingFiles {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("사진 목록 불러오는 중...")
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
            }

            // 우측 상단 전체 화면 아이콘
            if model.selectedPhoto != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button { model.enterFullScreen() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("전체 화면")
                    }
                    Spacer()
                }
                .padding(10)
            }

            // 하단 상태바 오버레이
            if let photo = model.selectedPhoto {
                VStack {
                    Spacer()
                    HStack(spacing: Theme.s3) {
                        Text(model.selectedIDs.count > 1 ? "\(model.selectedIDs.count)장 선택됨" : photo.name)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1).truncationMode(.middle)
                        StarRatingView(rating: photo.rating) { newRating in
                            model.setRating(newRating, for: photo)
                        }
                        Spacer()
                        if model.isLoadingMetadata {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.6)
                                Text("\(model.loadProgress.done)/\(model.loadProgress.total)")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        Text("\((model.selectedIndex ?? 0) + 1) / \(model.photos.count)")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, Theme.s2)
                    .background(Theme.overlayBG, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .padding(Theme.s3)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 키 입력은 ContentView의 글로벌 NSEvent 모니터에서 처리 (포커스 독립)
    }
}

// MARK: - Video player

/// AVPlayerLayer를 백킹 레이어로 직접 소유해 contentsScale을 처음부터 제어,
/// Retina 초기 흐림을 방지한다. AVPlayerView 내부 레이어는 지연 생성·자체 관리되어
/// 서브클래스에서 contentsScale을 심어도 덮여쓰이므로 이 방식을 사용한다.
final class PlayerLayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        applyScale()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        playerLayer.contentsScale = scale
    }
}

struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerNSView {
        PlayerLayerNSView(player: player)
    }
    func updateNSView(_ v: PlayerLayerNSView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var scopedRoot: URL?

    var body: some View {
        Group {
            if let player {
                PlayerViewRepresentable(player: player)
                    .onAppear { player.play() }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            player?.pause()
            player = nil
            scopedRoot?.stopAccessingSecurityScopedResource()
            scopedRoot = nil

            if let root = RootFolderStore.shared.root(containing: url),
               root.startAccessingSecurityScopedResource() {
                scopedRoot = root
                Logger.video.debug("scoped access started for root: \(root.lastPathComponent, privacy: .public)")
            } else {
                Logger.video.debug("scoped access skipped (no matching root) for: \(url.lastPathComponent, privacy: .public)")
            }

            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
            Logger.video.debug("AVPlayer created for \(url.lastPathComponent, privacy: .public) status=\(newPlayer.status.rawValue)")
        }
        .onDisappear {
            player?.pause()
            player = nil
            scopedRoot?.stopAccessingSecurityScopedResource()
            scopedRoot = nil
        }
    }
}

// MARK: - Full-resolution image with downsampling (High #7)

/// 사진 표시 + 트랙패드 핀치 줌. 확대 상태에서는 드래그로 이동한다.
struct PhotoImageView: View {
    let photo: PhotoItem
    /// 확대하지 않은 상태에서 사진을 Finder 등으로 끌어내기 허용 (센터 뷰)
    var allowsDragOut = false

    @State private var image: NSImage? = nil
    /// 확대 시 불러오는 고해상도 이미지 (기본 표시용은 2048px로 축소되어 확대하면 흐려짐)
    @State private var zoomImage: NSImage? = nil

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private let maxScale: CGFloat = 8
    /// 이 배율을 넘으면 고해상도 이미지를 불러온다
    private let hiResThreshold: CGFloat = 1.5

    private var isZoomed: Bool { scale > 1.001 }

    var body: some View {
        GeometryReader { geo in
            content
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .clipped()
                .gesture(magnifyGesture(in: geo.size))
                .gesture(panGesture(in: geo.size), including: isZoomed ? .all : .subviews)
                .modifier(DragOutModifier(url: photo.url, enabled: allowsDragOut && !isZoomed))
        }
        .task(id: photo.url) {
            // 사진이 바뀌면 배율 초기화
            resetZoom(animated: false)
            zoomImage = nil
            // ⚠️ image = nil로 리셋하지 않는다.
            // 리셋하면 새 사진이 로드될 때까지 ProgressView가 깜빡인다.
            // 이전 사진을 그대로 두면 새 이미지가 준비된 순간 cross-fade되어 자연스러움.
            // 새 사진 로드가 실패하면 image = nil이 되어 아래의 썸네일 fallback이 작동.
            let url = photo.url
            let loaded = await Task.detached {
                PhotoMetadata.loadDisplayImage(from: url)
            }.value
            if Task.isCancelled { return }
            image = loaded
        }
        .task(id: scale > hiResThreshold) {
            guard scale > hiResThreshold, zoomImage == nil else { return }
            let url = photo.url
            let loaded = await Task.detached(priority: .userInitiated) {
                PhotoMetadata.loadZoomImage(from: url)
            }.value
            // 불러오는 사이 다른 사진으로 넘어갔으면 버린다
            if Task.isCancelled || url != photo.url { return }
            zoomImage = loaded
        }
    }

    @ViewBuilder
    private var content: some View {
        if let img = zoomImage ?? image {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let thumb = photo.thumbnail {
            // 풀해상도가 아직 도착 안 했을 때 썸네일을 임시로 보여준다.
            // 첫 폴더 첫 사진에서 ProgressView만 보이는 빈 화면을 줄이는 게 핵심.
            Image(nsImage: thumb)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .padding(8)
                }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Zoom

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // 축소 방향은 살짝만 허용 (손을 떼면 1배로 복귀)
                let newScale = min(max(baseScale * value.magnification, 0.8), maxScale)
                // 핀치를 시작한 지점이 손가락 아래에 고정되도록 offset 보정
                let anchor = CGPoint(x: value.startLocation.x - size.width / 2,
                                     y: value.startLocation.y - size.height / 2)
                let contentX = (anchor.x - baseOffset.width) / baseScale
                let contentY = (anchor.y - baseOffset.height) / baseScale
                scale = newScale
                offset = CGSize(width: anchor.x - contentX * newScale,
                                height: anchor.y - contentY * newScale)
            }
            .onEnded { _ in
                if scale <= 1 {
                    resetZoom(animated: true)
                } else {
                    baseScale = scale
                    withAnimation(.easeOut(duration: 0.15)) {
                        offset = clampedOffset(offset, in: size)
                    }
                    baseOffset = offset
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clampedOffset(CGSize(width: baseOffset.width + value.translation.width,
                                              height: baseOffset.height + value.translation.height),
                                       in: size)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    /// 확대된 사진의 가장자리가 화면 안쪽으로 들어오지 않도록 이동 범위 제한
    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let fitted = fittedSize(in: size)
        let limitX = max(0, (fitted.width * scale - size.width) / 2)
        let limitY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(width: min(max(proposed.width, -limitX), limitX),
                      height: min(max(proposed.height, -limitY), limitY))
    }

    /// 1배율에서 화면에 맞춰(.fit) 표시되는 사진 크기
    private func fittedSize(in size: CGSize) -> CGSize {
        guard let imgSize = (zoomImage ?? image ?? photo.thumbnail)?.size,
              imgSize.width > 0, imgSize.height > 0 else { return size }
        let ratio = min(size.width / imgSize.width, size.height / imgSize.height)
        return CGSize(width: imgSize.width * ratio, height: imgSize.height * ratio)
    }

    private func resetZoom(animated: Bool) {
        let apply = {
            scale = 1
            offset = .zero
        }
        if animated { withAnimation(.easeOut(duration: 0.2), apply) } else { apply() }
        baseScale = 1
        baseOffset = .zero
    }
}

/// 확대 중에는 드래그가 사진 이동이어야 하므로 끌어내기(onDrag)를 끈다.
private struct DragOutModifier: ViewModifier {
    let url: URL
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(object: url as NSURL) }
        } else {
            content
        }
    }
}

// MARK: - Thumbnail strip

struct ThumbnailStrip: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: Theme.s1) {
                    ForEach(model.visiblePhotos, id: \.id) { photo in
                        ThumbnailCell(photo: photo, isSelected: model.selectedIDs.contains(photo.id))
                            .id(photo.id)
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture().onEnded {
                                Logger.video.debug("tap: \(photo.name, privacy: .public) isVideo=\(photo.isVideo)")
                                guard let idx = model.photos.firstIndex(where: { $0.id == photo.id }) else { return }
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) {
                                    model.toggleSelect(at: idx)
                                } else if mods.contains(.shift) {
                                    model.rangeSelect(to: idx)
                                } else {
                                    model.click(at: idx)
                                }
                            })
                            .onDrag { NSItemProvider(object: photo.url as NSURL) }
                            .contextMenu {
                                Button("삭제", role: .destructive) { model.deleteFromContext(photo) }
                                Button("복사") { model.copyFromContext(photo) }
                                Divider()
                                Button("EXIF 보기") { model.showExif(for: photo) }
                                Divider()
                                Button("새로고침") { model.reloadCurrentFolder() }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, Theme.s1)
                // ⚠️ LazyHStack에 .id(currentFolderURL)을 걸어 강제 재생성하지 않는다.
                // 각 셀이 .id(photo.id)로 식별되므로 ForEach가 자연스럽게 diff한다.
                // 강제 재생성은 폴더 전환 시 LazyHStack 전체가 깜빡이는 원인이었다.
            }
            .onChange(of: model.selectedIndex) { _, newIdx in
                guard let idx = newIdx, model.photos.indices.contains(idx) else { return }
                let targetID = model.photos[idx].id
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
            // 폴더 전환 시 첫 사진으로 스크롤 리셋. photos가 새 배열로 swap된 뒤에
            // 호출되어야 하므로 photos.first?.id 자체의 변화를 트리거로 사용.
            .onChange(of: model.photos.first?.id) { _, newFirstID in
                guard let id = newFirstID else { return }
                proxy.scrollTo(id, anchor: .leading)
            }
        }
        .background(Color(red: 0.15, green: 0.15, blue: 0.15))
    }
}

struct ThumbnailCell: View {
    let photo: PhotoItem
    let isSelected: Bool

    var body: some View {
        ZStack {
            if let thumb = photo.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.25)
                Image(systemName: "photo")
                    .foregroundColor(.gray)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .overlay(alignment: .center) {
            if photo.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if photo.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...photo.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(3)
                .allowsHitTesting(false)
            }
        }
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Star rating

struct StarRatingView: View {
    let rating: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSelect(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 21))
                        .foregroundColor(star <= rating ? .yellow : .white.opacity(0.5))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Rating filter bar

struct RatingFilterBar: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        HStack(spacing: Theme.s1) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            clearButton
            ForEach(1...5, id: \.self) { star in
                starFilterButton(star)
            }
            Spacer()
            if !model.ratingFilter.isEmpty {
                Text("\(model.visiblePhotos.count) / \(model.photos.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Theme.s3)
        .padding(.vertical, Theme.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelBG)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 1), alignment: .top)
    }

    private var clearButton: some View {
        Button {
            model.ratingFilter = []
        } label: {
            Text("전체")
                .font(.system(size: 14))
                .foregroundColor(model.ratingFilter.isEmpty ? .white : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(model.ratingFilter.isEmpty ? Color.accentColor : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func starFilterButton(_ star: Int) -> some View {
        let active = model.ratingFilter.contains(star)
        Button {
            model.toggleRatingFilter(star)
        } label: {
            Text("\(star)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 30, height: 30)
                .background(active ? Color.accentColor : Color.clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fullscreen overlay

struct FullScreenPhotoView: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let photo = model.selectedPhoto {
                if photo.isVideo {
                    VideoPlayerView(url: photo.url)
                        .id(photo.url)
                } else {
                    PhotoImageView(photo: photo)
                }
            }

            // 닫기 버튼 (우측 상단)
            VStack {
                HStack {
                    Spacer()
                    Button { model.isFullScreen = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                    .help("닫기 (ESC)")
                }
                Spacer()
            }
        }
        .onTapGesture(count: 2) { model.isFullScreen = false }
    }
}

// MARK: - Stacked Photos View

struct StackedPhotosView: View {
    let photos: [PhotoItem]
    let topID: UUID?
    private let maxCards = 12

    var body: some View {
        let shown = Array(photos.suffix(maxCards))
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, photo in
                card(photo)
                    .rotationEffect(.degrees(jitter(idx).angle))
                    .offset(x: jitter(idx).dx, y: jitter(idx).dy)
                    .zIndex(photo.id == topID ? 1000 : Double(idx))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .animation(.easeInOut(duration: 0.15), value: photos.map(\.id))
    }

    @ViewBuilder private func card(_ photo: PhotoItem) -> some View {
        Group {
            if let thumb = photo.thumbnail {
                Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(maxWidth: 400, maxHeight: 400)
        .padding(6)
        .background(Color.white)
        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
    }

    private func jitter(_ i: Int) -> (angle: Double, dx: CGFloat, dy: CGFloat) {
        func rnd(_ s: Double) -> Double { let v = sin(s) * 43758.5453; return v - floor(v) }
        let angle = (rnd(Double(i) * 12.9898) - 0.5) * 16
        let dx = CGFloat((rnd(Double(i) * 78.233) - 0.5) * 80)
        let dy = CGFloat((rnd(Double(i) * 37.719) - 0.5) * 60)
        return (angle, dx, dy)
    }
}
