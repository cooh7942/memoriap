import SwiftUI
import AVKit
import os

struct CenterView: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            PhotoDisplayArea(model: model)
            Divider()
            RatingFilterBar(model: model)
            ThumbnailStrip(model: model)
                .frame(height: 100)
        }
        .onChange(of: model.ratingFilter) { _, _ in
            model.applyRatingFilter()
        }
    }
}

// MARK: - Main photo display

struct PhotoDisplayArea: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.1)

            if let photo = model.selectedPhoto {
                Group {
                    if photo.isVideo {
                        let _ = Logger.video.debug("display video: \(photo.name, privacy: .public)")
                        VideoPlayerView(url: photo.url)
                            .id(photo.url)
                    } else {
                        PhotoImageView(photo: photo)
                            .onDrag { NSItemProvider(object: photo.url as NSURL) }
                    }
                }
                .onTapGesture(count: 2) { model.enterFullScreen() }
            } else if model.isLoadingFiles {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("사진 목록 불러오는 중...")
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text(model.currentFolderURL == nil ? "좌측에서 폴더를 선택하세요" : "이 폴더에 사진이 없습니다")
                        .foregroundColor(.secondary)
                }
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
                    HStack {
                        Text(photo.name)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        StarRatingView(rating: photo.rating) { newRating in
                            model.setRating(newRating, for: photo)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                        // High #6: 메타데이터 로딩 진행 표시
                        if model.isLoadingMetadata {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("\(model.loadProgress.done)/\(model.loadProgress.total)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text("\((model.selectedIndex ?? 0) + 1) / \(model.photos.count)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 키 입력은 ContentView의 글로벌 NSEvent 모니터에서 처리 (포커스 독립)
    }
}

// MARK: - Video player

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

struct PhotoImageView: View {
    let photo: PhotoItem
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
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
            }
        }
        .task(id: photo.url) {
            // ⚠️ image = nil로 리셋하지 않는다.
            // 리셋하면 새 사진이 로드될 때까지 ProgressView가 깜빡인다.
            // 이전 사진을 그대로 두면 새 이미지가 준비된 순간 cross-fade되어 자연스러움.
            // 새 사진 로드가 실패하면 image = nil이 되어 위의 썸네일 fallback이 작동.
            let url = photo.url
            let loaded = await Task.detached {
                PhotoMetadata.loadDisplayImage(from: url)
            }.value
            if Task.isCancelled { return }
            image = loaded
        }
    }
}

// MARK: - Thumbnail strip

struct ThumbnailStrip: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
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
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
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
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
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
                            .font(.system(size: 5))
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
        .scaleEffect(isSelected ? 1.05 : 1.0)
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

private struct RatingFilterBar: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
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
