import SwiftUI
import MapKit
import CoreLocation
import os

struct PhotoMapView: View {
    @ObservedObject var model: PhotoBrowserModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasFitted = false

    var photosWithCoords: [PhotoItem] { model.photosWithCoordinates }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mapArea
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Label("지도", systemImage: "map")
                .font(.headline)
            Spacer()
            if !photosWithCoords.isEmpty {
                Button { fitMapToAllPhotos() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("전체 위치 보기")

                Text("위치 \(photosWithCoords.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Map area
    // Map을 항상 렌더링해 두고 비어 있을 때만 overlay로 덮음.
    // if/else로 Map을 조건부 생성하면 첫 레이아웃 패스에서 0×0 크기가
    // Metal 레이어에 전달되어 CAMetalLayer 경고가 발생하므로 이 구조가 더 안전함.

    private var mapArea: some View {
        ZStack {
            Map(position: $cameraPosition) {
                ForEach(photosWithCoords) { photo in
                    if let coord = photo.coordinate {
                        Annotation("", coordinate: coord, anchor: .bottom) {
                            PhotoPinView(
                                photo: photo,
                                isSelected: model.selectedPhoto?.id == photo.id
                            )
                            .onTapGesture {
                                if let idx = model.photos.firstIndex(where: { $0.id == photo.id }) {
                                    model.selectPhoto(at: idx)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: model.isLoadingMetadata) { _, loading in
                if !loading, !hasFitted, !photosWithCoords.isEmpty {
                    hasFitted = true
                    fitMapToAllPhotos()
                }
            }
            .onChange(of: model.currentFolderURL) { _, _ in
                hasFitted = false
            }
            .onChange(of: model.selectedPhoto?.id) { _, _ in
                guard let coord = model.selectedPhoto?.coordinate else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))
                }
            }

            // 빈 상태 플레이스홀더 — Map 위에 overlay로만 표시
            if photosWithCoords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    if model.isLoadingMetadata {
                        ProgressView("GPS 정보 분석 중...")
                            .font(.callout)
                    } else {
                        Text("GPS 정보가 있는\n사진이 없습니다")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Fit

    private func fitMapToAllPhotos() {
        let coords = photosWithCoords.compactMap { $0.coordinate }
        guard !coords.isEmpty else { return }

        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }

        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.5, 0.02),
            longitudeDelta: max((lons.max()! - lons.min()!) * 1.5, 0.02)
        )

        withAnimation(.easeInOut(duration: 0.5)) {
            cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

// MARK: - Map pin with photo thumbnail

struct PhotoPinView: View {
    let photo: PhotoItem
    let isSelected: Bool

    private var size: CGFloat { isSelected ? 50 : 38 }

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.blue.opacity(0.9))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.3), radius: isSelected ? 5 : 3)

            if let thumb = photo.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size - 6, height: size - 6)
                    .clipShape(Circle())
            } else {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.35))
                    .foregroundColor(.white)
            }

            if isSelected {
                Circle()
                    .stroke(Color.white, lineWidth: 2.5)
                    .frame(width: size - 2, height: size - 2)
            }
        }
        .animation(.spring(duration: 0.25), value: isSelected)
    }
}
