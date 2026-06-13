import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import os

// MARK: - TreeNode
//
// 사이드바 트리의 단일 노드. depth는 들여쓰기 수준이며, 모든 노드는 List에서 동일한
// 단일 행(=형제 row)으로 그려진다 — 이를 통해 macOS List가 우클릭/스크롤 대상을
// 올바른 노드로 분기해 보낼 수 있다. (이전의 중첩 VStack 방식은 자손 위 우클릭에서도
// 항상 루트 행의 contextMenu가 떠버리는 버그가 있었음.)

struct TreeNode: Identifiable, Equatable, Hashable {
    let url: URL
    let depth: Int
    var id: URL { url }
}

// MARK: - SidebarTreeModel
//
// 한 트리 섹션의 펼침 상태와 가시 노드 배열을 관리.
// expand/collapse가 일어나면 visibleNodes에 직접 자식들이 삽입/제거되어,
// SidebarView의 ForEach가 flat한 형제 row로 그릴 수 있게 된다.

@MainActor
final class SidebarTreeModel: ObservableObject {
    @Published private(set) var visibleNodes: [TreeNode] = []
    @Published private(set) var expandedURLs: Set<URL> = []

    /// 트리의 루트 노드들을 설정 (예: 사용자 지정 루트들)
    func setRoots(_ urls: [URL]) {
        // 펼침 상태는 유지하되 새 루트만 깊이 0으로 깔고, 펼쳐진 것들은 다시 열기.
        // 부모를 먼저 펼쳐야 자손이 visibleNodes에 들어오므로 depth(=경로 컴포넌트 수) 오름차순으로 처리.
        let previouslyExpanded = expandedURLs
        expandedURLs = []
        visibleNodes = urls.map { TreeNode(url: $0, depth: 0) }
        let toExpand = previouslyExpanded
            .filter { url in urls.contains(where: { url.path.hasPrefix($0.path) }) }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in toExpand {
            if visibleNodes.contains(where: { $0.url == url }) {
                expand(url)
            }
        }
    }

    func isExpanded(_ url: URL) -> Bool {
        expandedURLs.contains(url)
    }

    func toggle(_ url: URL) {
        if expandedURLs.contains(url) {
            collapse(url)
        } else {
            expand(url)
        }
    }

    /// `url`을 펼침. 자식이 없으면 펼침 상태는 토글하지 않음.
    func expand(_ url: URL) {
        guard !expandedURLs.contains(url) else { return }
        guard let idx = visibleNodes.firstIndex(where: { $0.url == url }) else { return }
        let children = Self.loadDirectChildren(of: url)
        guard !children.isEmpty else { return }
        expandedURLs.insert(url)
        let depth = visibleNodes[idx].depth + 1
        let newNodes = children.map { TreeNode(url: $0, depth: depth) }
        visibleNodes.insert(contentsOf: newNodes, at: idx + 1)
    }

    func collapse(_ url: URL) {
        guard expandedURLs.contains(url) else { return }
        expandedURLs.remove(url)
        guard let idx = visibleNodes.firstIndex(where: { $0.url == url }) else { return }
        let parentDepth = visibleNodes[idx].depth
        var endIdx = idx + 1
        while endIdx < visibleNodes.count && visibleNodes[endIdx].depth > parentDepth {
            // 자손도 펼쳐져 있었다면 같이 정리
            expandedURLs.remove(visibleNodes[endIdx].url)
            endIdx += 1
        }
        if endIdx > idx + 1 {
            visibleNodes.removeSubrange((idx + 1)..<endIdx)
        }
    }

    /// `target`에 도달하기 위한 모든 조상 노드를 펼침(target 자체는 펼치지 않음).
    /// 이 트리의 루트들 중 어느 것이 target의 prefix인지 자동 판별.
    func revealAncestors(of target: URL) {
        guard let root = visibleNodes.first(where: { node in
            node.depth == 0 && target.path.hasPrefix(node.url.path)
        }) else { return }

        let targetComps = target.pathComponents
        let rootComps = root.url.pathComponents
        guard targetComps.count > rootComps.count else { return }

        var current = root.url
        var ancestors: [URL] = [root.url]  // root는 이미 visible
        for i in rootComps.count..<(targetComps.count - 1) {
            current.appendPathComponent(targetComps[i])
            ancestors.append(current)
        }
        for a in ancestors {
            if !expandedURLs.contains(a) {
                expand(a)
            }
        }
    }

    /// `url`이 현재 펼쳐진 상태라면 자손을 디스크에서 다시 읽어 visibleNodes를 갱신.
    /// 펼쳐지지 않은 폴더는 다음 expand 시 자연스럽게 새 내용으로 로드되므로 no-op.
    func reloadChildren(of url: URL) {
        guard expandedURLs.contains(url) else { return }
        guard let idx = visibleNodes.firstIndex(where: { $0.url == url }) else { return }

        // 기존 자손 범위 잘라내기 + expandedURLs에서도 정리
        let parentDepth = visibleNodes[idx].depth
        var endIdx = idx + 1
        while endIdx < visibleNodes.count && visibleNodes[endIdx].depth > parentDepth {
            expandedURLs.remove(visibleNodes[endIdx].url)
            endIdx += 1
        }
        if endIdx > idx + 1 {
            visibleNodes.removeSubrange((idx + 1)..<endIdx)
        }

        // 새 자식 로드 및 삽입
        let children = Self.loadDirectChildren(of: url)
        guard !children.isEmpty else {
            // 자식이 모두 사라졌으면 expanded 상태도 해제
            expandedURLs.remove(url)
            return
        }
        let newNodes = children.map { TreeNode(url: $0, depth: parentDepth + 1) }
        visibleNodes.insert(contentsOf: newNodes, at: idx + 1)
    }

    nonisolated static func loadDirectChildren(of url: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return contents.compactMap { childURL -> URL? in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: childURL.path, isDirectory: &isDir)
            return isDir.boolValue ? childURL : nil
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject var model: PhotoBrowserModel
    @StateObject private var locationsTree = SidebarTreeModel()
    @ObservedObject private var folderStore = RootFolderStore.shared
    @StateObject private var selection = SidebarSelection()
    @State private var didRevealInitialFolder = false

    var body: some View {
        ScrollViewReader { proxy in
            SidebarTreeList(
                tree: locationsTree,
                folderStore: folderStore,
                model: model,
                selection: selection,
                customFavorites: model.customFavorites
            )
            // currentFolderURL(선택) 변경을 List 본체가 아니라 이 래퍼에서 처리한다.
            // 선택 표시는 selection 객체로 미러링하여 개별 행만 갱신되게 하고,
            // 트리 밖(즐겨찾기)에서 점프한 경우에만 스크롤한다.
            // → 선택이 바뀌어도 SidebarTreeList(List 본체)는 재평가되지 않아 스크롤이 안 튄다.
            .onChange(of: model.currentFolderURL) { _, newURL in
                selection.update(newURL)
                guard let newURL else { return }
                let wasInTree = locationsTree.visibleNodes.contains { $0.url == newURL }
                locationsTree.revealAncestors(of: newURL)
                let isNowInTree = locationsTree.visibleNodes.contains { $0.url == newURL }
                if !wasInTree && isNowInTree {
                    scrollTo(url: newURL, proxy: proxy)
                }
            }
            // 시작 시: 마지막 폴더가 복원되면 그 위치까지 트리를 펼치고 스크롤
            .task {
                guard !didRevealInitialFolder else { return }
                didRevealInitialFolder = true
                selection.update(model.currentFolderURL)
                // List가 초기 루트 노드들을 렌더할 시간을 주고 시작
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let current = model.currentFolderURL {
                    locationsTree.revealAncestors(of: current)
                    scrollTo(url: current, proxy: proxy)
                }
            }
        }
    }

    private func scrollTo(url: URL, proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(url, anchor: .center)
            }
        }
    }
}

// MARK: - SidebarSelection
//
// 사이드바의 "현재 선택된 폴더"만 담는 경량 상태. List 본체(SidebarTreeList)가 아니라
// 개별 행(FlatFolderRow)만 이걸 구독한다. 선택이 바뀌면 해당 행들만 색·굵기를 갱신할 뿐
// List 전체가 재빌드되지 않으므로 NSTableView 스크롤이 위아래로 튀지 않는다.

@MainActor
final class SidebarSelection: ObservableObject {
    private(set) var current: URL?
    /// 선택 변경을 행들에게 알리는 퍼블리셔. @Published를 쓰지 않는 이유는, 행이
    /// @ObservedObject로 관찰하면 선택이 바뀔 때마다 *모든* 행이 재평가되기 때문이다
    /// (긴 트리에서 NSTableView 스크롤이 튀던 원인). 행은 이 퍼블리셔만 구독해
    /// 자기 선택 여부가 실제로 바뀔 때만 갱신된다.
    let changes = PassthroughSubject<URL?, Never>()

    func update(_ url: URL?) {
        guard current != url else { return }
        current = url
        changes.send(url)
    }
}

// MARK: - SidebarTreeList
//
// 실제 사이드바 List 본체. model·selection을 @ObservedObject로 관찰하지 않고 비관찰
// 참조로만 보유한다(메서드 호출·행 전달용). 따라서 photos·loadProgress는 물론
// 선택(currentFolderURL) 변경에도 이 뷰는 재평가되지 않는다 — List 재빌드·스크롤 튐 제거.

private struct SidebarTreeList: View {
    @ObservedObject var tree: SidebarTreeModel
    @ObservedObject var folderStore: RootFolderStore
    let model: PhotoBrowserModel
    let selection: SidebarSelection
    let customFavorites: [URL]

    @State private var mountObserver: NSObjectProtocol?
    @State private var unmountObserver: NSObjectProtocol?

    var body: some View {
        // List(.sidebar) 대신 ScrollView+LazyVStack — NSTableView를 쓰지 않으므로
        // 선택 변경 시 AppKit이 자동 스크롤하지 않아 트리가 위아래로 튀지 않는다.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !customFavorites.isEmpty {
                    SidebarSectionHeader(title: "즐겨찾기")
                    ForEach(customFavorites, id: \.self) { fav in
                        FlatFolderRow(
                            node: TreeNode(url: fav, depth: 0),
                            isExpanded: false,
                            isExpandable: false,
                            selection: selection,
                            onToggle: {},
                            model: model,
                            isUserAdded: true
                        )
                        .id(FavoriteID(fav))
                    }
                }

                AddFolderButton(onTap: { openFolderPicker() })
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                SidebarSectionHeader(title: "사진 폴더")
                ForEach(tree.visibleNodes) { node in
                    FlatFolderRow(
                        node: node,
                        isExpanded: tree.isExpanded(node.url),
                        isExpandable: true,
                        selection: selection,
                        onToggle: { tree.toggle(node.url) },
                        model: model
                    )
                    .id(node.url)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .onChange(of: folderStore.roots) { _, newRoots in
            tree.setRoots(newRoots)
        }
        .onAppear {
            tree.setRoots(folderStore.roots)
            mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil, queue: .main
            ) { _ in
                // 외장 디스크 재연결 시 savedBookmarks에 보존된 북마크로 자동 복원 시도
                RootFolderStore.shared.retryUnavailable()
            }
            unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil, queue: .main
            ) { notification in
                guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let removed = RootFolderStore.shared.handleVolumeUnmount(volumeURL: volumeURL)
                guard !removed.isEmpty else { return }
                if let current = model.currentFolderURL,
                   current.path.hasPrefix(volumeURL.path) {
                    model.currentFolderURL = nil
                    model.photos = []
                    model.selectedIndex = nil
                    model.currentFolderBecameUnavailable = true
                }
                tree.setRoots(RootFolderStore.shared.roots)
            }
        }
        .onDisappear {
            if let o = mountObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(o)
                mountObserver = nil
            }
            if let o = unmountObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(o)
                unmountObserver = nil
            }
        }
        // 이름 변경·삭제 후 부모 폴더의 트리 자식 목록을 즉시 갱신
        .onReceive(model.folderChanged) { parent in
            HasChildrenCache.invalidate(parent)
            tree.reloadChildren(of: parent)
        }
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "추가할 사진 폴더를 선택하세요"
        panel.prompt = "추가"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            RootFolderStore.shared.add(url: url)
        }
    }
}

// 즐겨찾기 row가 트리에 있는 같은 URL과 ScrollViewReader id가 충돌하지 않도록 분리
private struct FavoriteID: Hashable {
    let url: URL
    init(_ url: URL) { self.url = url }
}

// MARK: - SidebarSectionHeader
//
// List(.sidebar)의 Section 헤더를 대체. ScrollView+LazyVStack에는 Section이 없으므로 직접 그린다.

private struct SidebarSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

// MARK: - AddFolderButton

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

// MARK: - FlatFolderRow
//
// 트리의 단일 행 — 모든 행은 List의 형제 row로 그려지며, depth만큼 들여쓰기.
// contextMenu는 자기 행의 HStack에만 부착되어 macOS List가 정확히 이 행의 메뉴를 띄움.

struct FlatFolderRow: View {
    let node: TreeNode
    /// 트리 상태를 부모가 계산해서 명시적으로 넘긴다 — SwiftUI가 row 단위로 diff를 정확히 감지하도록.
    /// (이전엔 `tree` 객체 참조로 받아서, topmost row처럼 위치·node가 그대로면 body 재평가를 건너뛰는 문제가 있었음.)
    let isExpanded: Bool
    let isExpandable: Bool
    /// selection을 @ObservedObject로 관찰하면 선택이 바뀔 때 *모든* 행이 재평가된다
    /// (긴 트리에서 NSTableView 스크롤이 튀던 원인). 대신 비관찰 참조로 들고 changes
    /// 퍼블리셔만 구독해(아래 onReceive), isSelected가 실제로 바뀐 행만 재평가되게 한다.
    let selection: SidebarSelection
    let onToggle: () -> Void
    /// 선택과 무관한 model 변경(photos·loadProgress 등)에 행이 재평가되지 않도록
    /// @ObservedObject가 아닌 비관찰 참조로 보유 — 메서드 호출 용도로만 사용한다.
    let model: PhotoBrowserModel
    @ObservedObject private var folderStore = RootFolderStore.shared
    var isUserAdded: Bool = false

    @State private var isSelected: Bool
    @State private var hasChildren: Bool?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var isDropTargeted = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""

    init(
        node: TreeNode,
        isExpanded: Bool,
        isExpandable: Bool,
        selection: SidebarSelection,
        onToggle: @escaping () -> Void,
        model: PhotoBrowserModel,
        isUserAdded: Bool = false
    ) {
        self.node = node
        self.isExpanded = isExpanded
        self.isExpandable = isExpandable
        self.selection = selection
        self.onToggle = onToggle
        self.model = model
        self.isUserAdded = isUserAdded
        self._isSelected = State(initialValue: selection.current == node.url)
        // 캐시에 값이 있으면 즉시 사용 → nil 상태를 거치지 않아 흔들림 없음
        self._hasChildren = State(initialValue: HasChildrenCache.get(node.url))
    }

    var url: URL { node.url }
    var depth: Int { node.depth }
    var displayName: String {
        let n = url.lastPathComponent
        return n.isEmpty ? url.path : n
    }
    var canExpand: Bool {
        isExpandable && hasChildren == true
    }

    var body: some View {
        HStack(spacing: 2) {
            // depth × 16pt 들여쓰기
            if depth > 0 {
                Color.clear.frame(width: CGFloat(depth) * 16, height: 1)
            }

            chevronArea

            HStack(spacing: 6) {
                Image(nsImage: FileIconCache.icon(for: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                Text(displayName)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await model.loadFolder(url: url) }
                if canExpand {
                    onToggle()
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.22) :
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadURLs(from: providers) { droppedURLs in
                guard !droppedURLs.isEmpty else { return }
                let selected = model.selectedURLs
                let sources: [URL]
                if droppedURLs.contains(where: { selected.contains($0) }) && selected.count > 1 {
                    sources = selected
                } else {
                    sources = droppedURLs
                }
                model.pendingDropOperation = PendingDropOperation(sources: sources, destination: url)
            }
            return true
        }
        .task {
            guard isExpandable else { return }
            if HasChildrenCache.get(url) != nil {
                // 캐시 히트: init에서 이미 초기값이 설정됨, 추가 작업 불필요
                return
            }
            await checkHasChildren()
        }
        .alert("이름 변경", isPresented: $isRenaming) {
            TextField("새 이름", text: $renameText)
            Button("확인") {
                guard !renameText.isEmpty else { return }
                try? model.renameItem(at: url, to: renameText)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("'\(displayName)'의 새 이름을 입력하세요")
        }
        .alert("폴더 삭제", isPresented: $showDeleteConfirm) {
            Button("휴지통으로 이동", role: .destructive) {
                try? model.deleteItem(at: url)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("'\(displayName)'을(를) 휴지통으로 이동하시겠습니까?")
        }
        .alert("새 폴더 만들기", isPresented: $isCreatingFolder) {
            TextField("폴더 이름", text: $newFolderName)
            Button("만들기") {
                guard !newFolderName.isEmpty else { return }
                try? model.createFolder(in: url, name: newFolderName)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("'\(displayName)' 안에 생성할 폴더 이름을 입력하세요")
        }
        // 모든 행이 selection.changes를 구독하지만, isSelected(@State)가 실제로 바뀌는
        // 행(이전 선택 해제 + 새 선택 = 2개)만 body가 재평가된다 → NSTableView 스크롤 안 튐.
        .onReceive(selection.changes) { newSelection in
            let nowSelected = (newSelection == url)
            if nowSelected != isSelected {
                isSelected = nowSelected
            }
        }
    }

    @ViewBuilder
    private var chevronArea: some View {
        if canExpand {
            // Button 대신 onTapGesture — macOS List(.sidebar) 안에서 Button이 행 선택과
            // 클릭이 섞여 안 먹는 케이스가 있음. contentShape으로 hit area도 확실히 확보.
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if isUserAdded {
            Button("즐겨찾기에서 제거", role: .destructive) {
                model.removeCustomFavorite(url)
            }
        } else {
            if folderStore.roots.contains(url) {
                Button("이 폴더를 목록에서 제거", role: .destructive) {
                    RootFolderStore.shared.remove(url: url)
                }
                Divider()
            }
            Button("즐겨찾기에 추가") {
                model.addCustomFavorite(url: url)
            }
            Divider()
            Button("새 폴더 만들기") {
                newFolderName = ""
                isCreatingFolder = true
            }
            Divider()
            Button("이름 변경") {
                renameText = displayName
                isRenaming = true
            }
            Button("휴지통으로 이동", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    private func checkHasChildren() async {
        let folderURL = url
        let result: Bool = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            ) else { return false }
            while let element = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: element.path, isDirectory: &isDir)
                if isDir.boolValue { return true }
            }
            return false
        }.value
        // 캐시에 저장 — 이후 같은 URL의 행이 생성될 때 즉시 사용
        HasChildrenCache.set(folderURL, result)
        hasChildren = result
    }

    private func loadURLs(from providers: [NSItemProvider],
                          completion: @escaping ([URL]) -> Void) {
        var collected: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            guard p.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(collected) }
    }
}

// MARK: - File icon cache
//
// NSWorkspace.shared.icon(forFile:)은 같은 경로에 대해서도 매번 새 NSImage 인스턴스를
// 반환할 수 있어, SwiftUI가 그걸 변경으로 보고 행을 재렌더한다(=플리커 원인).
// 경로 → NSImage를 process-lifetime 동안 보유해 동일 인스턴스를 재사용.

private enum FileIconCache {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

// MARK: - Has-children cache
//
// FlatFolderRow가 새로 생성될 때마다 hasChildren이 nil로 리셋되어
// chevron이 뒤늦게 나타나며 행이 흔들리는 문제를 방지한다.
// 경로 → Bool을 프로세스 수명 동안 보유해 동일 인스턴스를 재사용.

private enum HasChildrenCache {
    private static let lock = NSLock()
    private static var cache: [URL: Bool] = [:]

    static func get(_ url: URL) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    static func set(_ url: URL, _ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        cache[url] = value
    }

    static func invalidate(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: url)
    }
}
