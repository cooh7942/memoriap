import SwiftUI
import AppKit
import os

struct ContentView: View {
    @StateObject private var model = PhotoBrowserModel()
    @ObservedObject private var folderStore = RootFolderStore.shared
    @State private var eventMonitor: Any? = nil
    @State private var skipDeleteConfirm = false
    @State private var showUnavailableAlert = false
    @State private var unmountedFolderNames: [String] = []

    var body: some View {
        Group {
            if folderStore.roots.isEmpty {
                FolderPickerOnboardingView(onPick: { openFolderPicker() })
            } else {
                mainLayout
            }
        }
        .task {
            await model.restoreSession()
            if !RootFolderStore.shared.unavailableNames.isEmpty {
                unmountedFolderNames = RootFolderStore.shared.unavailableNames
                showUnavailableAlert = true
            }
            if RootFolderStore.shared.roots.isEmpty {
                openFolderPicker()
            }
        }
        .onChange(of: model.currentFolderBecameUnavailable) { _, became in
            if became {
                model.currentFolderBecameUnavailable = false
                unmountedFolderNames = RootFolderStore.shared.unavailableNames
                showUnavailableAlert = true
                if RootFolderStore.shared.roots.isEmpty {
                    openFolderPicker()
                }
            }
        }
        .alert(
            "연결이 끊긴 폴더",
            isPresented: $showUnavailableAlert
        ) {
            Button("확인", role: .cancel) {
                unmountedFolderNames = []
            }
        } message: {
            Text("다음 폴더에 접근할 수 없습니다 (외장 디스크가 분리되었거나 경로가 변경되었을 수 있습니다):\n\n"
                 + unmountedFolderNames.map { "• \($0)" }.joined(separator: "\n"))
        }
        // 에러 알림
        .alert(
            "오류",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("확인", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        // 손상 파일 경고
        .alert("손상된 사진 파일이 있습니다.", isPresented: $model.showCorruptedWarning) {
            Button("확인", role: .cancel) { model.corruptedFileNames = [] }
        } message: {
            if model.corruptedFileNames.isEmpty {
                Text("일부 사진 파일을 불러올 수 없어 목록에서 제외했습니다.")
            } else {
                Text("다음 파일을 불러올 수 없어 제외했습니다:\n\n"
                     + model.corruptedFileNames.map { "• \($0)" }.joined(separator: "\n"))
            }
        }
    }

    private var mainLayout: some View {
        ZStack {
            HSplitView {
                // 왼쪽: 파일 목록 — 전체 높이
                SidebarView(model: model)
                    .frame(minWidth: 80, idealWidth: 300, maxWidth: 400)

                // 오른쪽: 위(메인 | 지도) + 아래(썸네일)
                VStack(spacing: 0) {
                    HSplitView {
                        CenterView(model: model)
                            .frame(minWidth: 400)

                        PhotoMapView(model: model)
                            .frame(minWidth: 200, idealWidth: 300, maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)

                    Divider()

                    RatingFilterBar(model: model)
                    ThumbnailStrip(model: model)
                        .frame(height: 110)
                }
            }
            .frame(minWidth: 1100, minHeight: 700)
            .onChange(of: model.ratingFilter) { _, _ in
                model.applyRatingFilter()
            }

            if model.pendingDeletePhoto != nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)

                DeleteConfirmDialog(
                    photoName: model.pendingDeletePhoto?.name ?? "",
                    skipNextTime: $skipDeleteConfirm,
                    focusedChoice: Binding(
                        get: { model.deleteDialogFocus },
                        set: { model.deleteDialogFocus = $0 }
                    ),
                    onChoose: handleDeleteChoice
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            if model.pendingDropOperation != nil {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)

                CopyMoveConfirmDialog(
                    sourceCount: model.pendingDropOperation?.sources.count ?? 0,
                    destinationName: model.pendingDropOperation?.destination.lastPathComponent ?? "",
                    focusedChoice: Binding(
                        get: { model.dropDialogFocus },
                        set: { model.dropDialogFocus = $0 }
                    )
                ) { choice in
                    if let choice {
                        Task { await model.confirmDrop(mode: choice) }
                    } else {
                        model.cancelDrop()
                    }
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            if model.isFullScreen {
                FullScreenPhotoView(model: model)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.pendingDeletePhoto != nil || model.pendingDropOperation != nil)
        .animation(.easeInOut(duration: 0.15), value: model.isFullScreen)
        .overlay(alignment: .topTrailing) {
            if model.showExifPanel {
                ExifPanel(model: model)
                    .frame(width: 300)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showExifPanel)
        .onChange(of: model.pendingDeletePhoto != nil) { _, shown in
            if shown { model.deleteDialogFocus = .trash }
        }
        .onChange(of: model.pendingDropOperation != nil) { _, shown in
            if shown { model.dropDialogFocus = .cut }
        }
        // 툴바 로딩 스피너는 제거했다. if로 등장/퇴장시키면 툴바 높이가 변해 사이드바가
        // 위아래로 밀렸고(흔들림 원인), 항상 배치하면 빈 동그라미가 남았다.
        // 파일 로딩 표시는 가운데 PhotoDisplayArea가 담당한다.
        .onAppear { startEventMonitor() }
        .onDisappear { stopEventMonitor() }
    }

    private func handleDeleteChoice(_ choice: DeleteConfirmChoice) {
        switch choice {
        case .trash:
            if skipDeleteConfirm {
                UserDefaults.standard.set(true, forKey: "skipDeletePhotoConfirm")
            }
            model.performDeleteSelectedPhoto()
        case .cancel:
            model.pendingDeletePhoto = nil
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "사진 폴더의 루트를 선택하세요"
        panel.prompt = "선택"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            RootFolderStore.shared.add(url: url)
            Task { await model.loadFolder(url: url) }
        }
    }

    // High #4: 글로벌 키 처리 (포커스 독립)
    private func startEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 텍스트 입력 중이면 이벤트 통과 (이름 변경, 검색창 등)
            if let fr = NSApp.keyWindow?.firstResponder, fr is NSTextView {
                return event
            }
            // 모달(alert/sheet)이 떠 있으면 통과
            if NSApp.modalWindow != nil { return event }

            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // === ⌘C / ⌘X / ⌘V — Cmd 단독 조합만 가로챔 ===
            if mods == .command {
                switch event.keyCode {
                case 8: model.copySelectedPhoto(); return nil          // ⌘C
                case 7: model.cutSelectedPhoto(); return nil           // ⌘X
                case 9: Task { await model.pasteIntoCurrentFolder() }; return nil  // ⌘V
                default: return event  // ⌘W, ⌘Q 등은 통과
                }
            }

            // 나머지 modifier 조합(⌥, ⌃, ⌘⌥ 등)은 통과
            if !mods.isEmpty { return event }

            // === 전체 화면 활성 시: 다이얼로그 검사보다 앞에서 처리 ===
            if model.isFullScreen {
                switch event.keyCode {
                case 53:        // Escape → 복귀
                    model.isFullScreen = false
                    return nil
                case 123:       // ← 이전 사진
                    model.selectPrevious()
                    return nil
                case 124:       // → 다음 사진
                    model.selectNext()
                    return nil
                case 51, 117:   // Delete/Forward Delete → 무시
                    return nil
                default:        // 그 외 키는 전체 화면 밖으로 새지 않게 차단
                    return nil
                }
            }

            // === 삭제 다이얼로그 활성 시 ===
            if model.pendingDeletePhoto != nil {
                switch event.keyCode {
                case 125, 126:   // ↓/↑ → 선택 토글
                    model.deleteDialogFocus = (model.deleteDialogFocus == .trash) ? .cancel : .trash
                    return nil
                case 36, 76:     // Return, Keypad Enter → 실행
                    handleDeleteChoice(model.deleteDialogFocus)
                    return nil
                case 53:         // Escape → 취소
                    handleDeleteChoice(.cancel)
                    return nil
                default:
                    return nil   // 그 외 키는 다이얼로그 밖으로 새지 않게 차단
                }
            }

            // === 복사/이동 다이얼로그 활성 시 ===
            if model.pendingDropOperation != nil {
                switch event.keyCode {
                case 125, 126:   // ↓/↑ → 복사/이동 토글
                    model.dropDialogFocus = (model.dropDialogFocus == .copy) ? .cut : .copy
                    return nil
                case 36, 76:     // Return, Keypad Enter → 실행
                    let mode = model.dropDialogFocus
                    Task { await model.confirmDrop(mode: mode) }
                    return nil
                case 53:         // Escape → 취소
                    model.cancelDrop()
                    return nil
                default:
                    return nil
                }
            }

            // === 평상시 키 처리 (전체 화면은 위에서 이미 처리됨) ===
            switch event.keyCode {
            case 123:       // Left Arrow → 이전 사진
                model.selectPrevious()
                return nil
            case 124:       // Right Arrow → 다음 사진
                model.selectNext()
                return nil
            case 126:       // Up Arrow → 이전 폴더
                model.selectPreviousSiblingFolder()
                return nil
            case 125:       // Down Arrow → 다음 폴더
                model.selectNextSiblingFolder()
                return nil
            case 51, 117:   // Delete, Forward Delete
                model.handleDeleteKeyPress()
                return nil
            default:
                return event
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - EXIF floating panel

struct ExifPanel: View {
    @ObservedObject var model: PhotoBrowserModel
    @State private var sections: [ExifSection] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.selectedPhoto?.name ?? "EXIF")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { model.showExifPanel = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { sec in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sec.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(sec.rows, id: \.label) { row in
                                HStack(alignment: .top) {
                                    Text(row.label)
                                        .frame(width: 80, alignment: .leading)
                                        .foregroundColor(.secondary)
                                    Text(row.value)
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                .font(.callout)
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("EXIF 정보가 없습니다.")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
        .task(id: model.selectedPhoto?.url) {
            guard let url = model.selectedPhoto?.url else { sections = []; return }
            sections = await Task.detached { PhotoMetadata.readExif(from: url) }.value
        }
    }
}

struct FolderPickerOnboardingView: View {
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            Text("사진 폴더 선택")
                .font(.title2).bold()
            Text("사진이 저장된 루트 폴더를 선택하면\n하위 폴더의 모든 사진을 탐색할 수 있습니다.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("폴더 선택…", action: onPick)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
