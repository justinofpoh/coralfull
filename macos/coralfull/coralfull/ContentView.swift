//
//  ContentView.swift
//  coralfull
//
//
import AppKit
import Charts
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var store = SiteStore()
    @StateObject private var cardPreferences = SiteCardPreferences()
    @StateObject private var tagPreferences = SiteTagPreferences()
    @State private var selectedSiteID: String = builtInSites[0].id
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var selectedPriority: CoralSite.Priority?
    @State private var isHealthExpanded = true
    @State private var presentedScan: CoralSite?
    @State private var creationSelection: ImportSelection?
    @State private var processingSheetSiteID: ProcessingSheetTarget?
    @State private var importErrorMessage: String?
    @State private var renameTarget: CoralSite?
    @State private var deletionTarget: CoralSite?
    @State private var isTagCreationPresented = false
    @State private var tagAssignmentTarget: CoralSite?

    private var allSites: [CoralSite] {
        let sharedIDs = Set(builtInSites.map(\.id))
        let localOnlySites = store.sites.filter { !sharedIDs.contains($0.id) }
        let sharedSites = builtInSites
            .filter { !cardPreferences.hiddenBuiltInSiteIDs.contains($0.id) }
            .map { cardPreferences.applyingNameOverride(to: $0) }
        let sites = sharedSites + localOnlySites.map { uploaded in
            CoralSite(
                id: uploaded.id,
                name: uploaded.name,
                photoCount: uploaded.photoCount,
                priority: .medium,
                imageName: "",
                uploadedState: uploaded.state,
                coverImage: store.covers[uploaded.id]
            )
        }
        return sites.map(tagPreferences.applyingTags(to:))
    }

    private var selectedSite: CoralSite? {
        allSites.first { $0.id == selectedSiteID } ?? allSites.first
    }

    private var filteredSites: [CoralSite] {
        allSites.filter { site in
            let matchesSearch = searchText.isEmpty || site.name.localizedCaseInsensitiveContains(searchText)
            let matchesTag = selectedTag.map { selected in
                site.tags.contains { $0.localizedCaseInsensitiveCompare(selected) == .orderedSame }
            } ?? true
            let matchesPriority = selectedPriority.map { site.priority == $0 } ?? true
            return matchesSearch && matchesTag && matchesPriority
        }
    }

    var body: some View {
        Group {
            if presentedScan == nil {
                dashboardView
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            DashboardToolbar(
                                searchText: $searchText,
                                selectedTag: $selectedTag,
                                selectedPriority: $selectedPriority,
                                tags: tagPreferences.tags,
                                onCreateTag: { presentTagCreation() },
                                onCreateSite: presentPhotoPicker
                            )
                        }
                    }
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Search sites")
            }
            else {
                dashboardView
            }
        }
        // The dashboard is a three-pane macOS workspace. Keep enough room for
        // the sidebar, site grid, and inspector to remain side-by-side.
        .frame(minWidth: 1_260, minHeight: 760)
        .background(WindowSidebarToggleVisibility(isHidden: presentedScan != nil))
        .preferredColorScheme(presentedScan == nil ? .light : .dark)
        .overlay {
            if let presentedScan {
                scanView(for: presentedScan)
                    // Keep the native macOS window toolbar visible so its close,
                    // minimise, and zoom controls remain available in the 3D view.
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: presentedScan?.id)
        .sheet(item: $creationSelection) { selection in
            SiteCreationSheet(
                selection: selection.urls,
                store: store,
                onOpenAnalysis: { siteID in
                    creationSelection = nil
                    openUploadedAnalysis(siteID: siteID)
                },
                onDismiss: { creationSelection = nil }
            )
        }
        .sheet(item: $processingSheetSiteID) { target in
            SiteProcessingView(
                siteID: target.id,
                store: store,
                onOpenAnalysis: {
                    processingSheetSiteID = nil
                    openUploadedAnalysis(siteID: target.id)
                },
                onDismiss: { processingSheetSiteID = nil }
            )
            .frame(minWidth: 520, idealWidth: 640, maxWidth: 760, minHeight: 540, idealHeight: 620, maxHeight: 760)
        }
        .sheet(item: $renameTarget) { site in
            SiteRenameSheet(
                site: site,
                onSave: { name in rename(siteID: site.id, to: name) }
            )
        }
        .sheet(isPresented: $isTagCreationPresented) {
            TagCreationSheet(existingTags: tagPreferences.tags) { name in
                let tag = tagPreferences.create(name)
                if let site = tagAssignmentTarget {
                    tagPreferences.add(tag, to: site.id)
                }
                selectedTag = tag
            }
        }
        .alert(
            "Could not import photos",
            isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { if !$0 { importErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "")
        }
        .alert(
            "Delete \(deletionTarget?.name ?? "site")?",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            presenting: deletionTarget
        ) { site in
            Button("Delete", role: .destructive) {
                delete(siteID: site.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { site in
            Text(
                isBuiltInSite(site.id)
                    ? "This removes the card from this Mac. The bundled shared model stays inside the app."
                    : "This removes the site and its locally stored photos and processed files from this Mac."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugImportRequest)) { notification in
            #if DEBUG
            if let path = notification.object as? String {
                creationSelection = ImportSelection(urls: [URL(fileURLWithPath: path)])
            }
            #endif
        }
    }

    private func presentPhotoPicker() {
        SurveyPhotoPicker.present { urls in
            guard let urls, !urls.isEmpty else { return }
            creationSelection = ImportSelection(urls: urls)
        }
    }

    private func presentTagCreation(for site: CoralSite? = nil) {
        tagAssignmentTarget = site
        isTagCreationPresented = true
    }

    private func openUploadedAnalysis(siteID: String) {
        guard let site = allSites.first(where: { $0.id == siteID }) else { return }
        selectedSiteID = siteID
        withAnimation(.snappy) {
            presentedScan = site
        }
    }

    private func openSelectedScan() {
        guard let selectedSite else { return }
        let scanSite = selectedSite.has3DScan
        ? selectedSite
        : allSites.first(where: \.has3DScan)

        guard let scanSite else { return }

        withAnimation(.snappy) {
            presentedScan = scanSite
        }
    }

    private func rename(siteID: String, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isBuiltInSite(siteID) {
            cardPreferences.renameBuiltInSite(id: siteID, to: name)
        } else {
            store.rename(siteID: siteID, to: name)
        }
    }

    private func delete(siteID: String) {
        if isBuiltInSite(siteID) {
            cardPreferences.hideBuiltInSite(id: siteID)
        } else {
            store.delete(siteID: siteID)
        }
        deletionTarget = nil
        if selectedSiteID == siteID {
            selectedSiteID = allSites.first?.id ?? ""
        }
    }

    private func isBuiltInSite(_ siteID: String) -> Bool {
        builtInSites.contains { $0.id == siteID }
    }

    @ViewBuilder
    private func scanView(for site: CoralSite) -> some View {
        let close = {
            withAnimation(.snappy) {
                presentedScan = nil
            }
        }
        if let sharedSource = SiteAnalysisSource.sharedReference(for: site.id) {
            SiteAnalysisView(
                siteName: site.name,
                source: sharedSource,
                onClose: close
            )
        } else if site.uploadedState != nil {
            SiteAnalysisView(
                siteName: site.name,
                source: .uploaded(siteID: site.id, name: site.name),
                onClose: close
            )
        } else if site.hasMetashapeMesh {
            SiteAnalysisView(siteName: site.name, source: .siteB, onClose: close)
        } else {
            ReefScanView(site: site, onClose: close)
        }
    }

    @ViewBuilder
    private var dashboardView: some View {
        NavigationSplitView {

            // MARK: Sidebar
            DashboardSidebar(
                isShowingScan: presentedScan != nil,
                onOpen3DView: openSelectedScan
            )
        } content: {

            // MARK: Content
            DashboardContent(
                sites: filteredSites,
                selectedSiteID: $selectedSiteID,
                statuses: store.statuses,
                availableTags: tagPreferences.tags,
                onCreateSite: presentPhotoPicker,
                onRename: { renameTarget = $0 },
                onDelete: { deletionTarget = $0 },
                onToggleTag: { site, tag in tagPreferences.toggle(tag, for: site.id) },
                onCreateTagForSite: { presentTagCreation(for: $0) }
            )


        } detail: {
            if let selectedSite {
                SiteInspector(
                    site: selectedSite,
                    status: store.statuses[selectedSite.id],
                    isHealthExpanded: $isHealthExpanded,
                    onOpenScan: openSelectedScan,
                    onShowProgress: { processingSheetSiteID = ProcessingSheetTarget(id: selectedSite.id) },
                    onRetry: { store.retry(siteID: selectedSite.id) },
                    onDelete: { deletionTarget = selectedSite }
                )
            } else {
                ContentUnavailableView(
                    "No sites",
                    systemImage: "square.grid.2x2",
                    description: Text("Create a site from photos to add it to the dashboard.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// The sidebar toggle is a system-provided `NSToolbarItem`, separate from the
/// native macOS window controls. Hide that one item for the immersive 3D view
/// and restore it when the dashboard returns.
private struct WindowSidebarToggleVisibility: NSViewRepresentable {
    let isHidden: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.apply(isHidden: isHidden, to: view.window?.toolbar)
        }
    }

    final class Coordinator {
        private var sidebarItemIdentifier: NSToolbarItem.Identifier?
        private var sidebarItemIndex: Int?

        func apply(isHidden: Bool, to toolbar: NSToolbar?) {
            guard let toolbar else { return }

            if isHidden {
                guard let index = toolbar.items.firstIndex(where: isSidebarToggle) else { return }
                sidebarItemIdentifier = toolbar.items[index].itemIdentifier
                sidebarItemIndex = index
                toolbar.removeItem(at: index)
            } else if let sidebarItemIdentifier,
                      !toolbar.items.contains(where: isSidebarToggle) {
                toolbar.insertItem(
                    withItemIdentifier: sidebarItemIdentifier,
                    at: min(sidebarItemIndex ?? 0, toolbar.items.count)
                )
            }
        }

        private func isSidebarToggle(_ item: NSToolbarItem) -> Bool {
            item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebar") ||
                item.label.localizedCaseInsensitiveContains("sidebar")
        }
    }
}

/// Identifiable wrappers for sheet presentation.
private struct ImportSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ProcessingSheetTarget: Identifiable {
    let id: String
}

extension Notification.Name {
    /// DEBUG-only hook: DebugCapture posts this with a folder path to start
    /// the create-site flow without the native open panel.
    static let debugImportRequest = Notification.Name("coralfull.debugImportInternal")
}

private struct DashboardToolbar: View {
    @Binding var searchText: String
    @Binding var selectedTag: String?
    @Binding var selectedPriority: CoralSite.Priority?
    let tags: [String]
    let onCreateTag: () -> Void
    let onCreateSite: () -> Void

    var body: some View {
        HStack(spacing: 4) {

            // Create site
            Button(action: onCreateSite) {
                Label("Create site", systemImage: "plus")
            }
            .help("Create a new site from survey photos")

            // Tags
            Menu {
                Button {
                    selectedTag = nil
                } label: {
                    Label("All Sites", systemImage: "square.grid.2x2")
                }

                if !tags.isEmpty {
                    Divider()
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            selectedTag = tag
                        } label: {
                            HStack {
                                Text(tag)
                                if selectedTag == tag {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()
                Button("Create Tag…", systemImage: "plus", action: onCreateTag)
            } label: {
                Text(selectedTag ?? "Sites")
            }
            .menuStyle(.borderlessButton)

            // Priority filter
            Menu {
                Button {
                    selectedPriority = nil
                } label: {
                    HStack {
                        Text("All")
                        if selectedPriority == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(CoralSite.Priority.allCases) { priority in
                    Button {
                        selectedPriority = priority
                    } label: {
                        HStack {
                            Text(priority.title)

                            if selectedPriority == priority {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(selectedPriority?.title ?? "Priority")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
        }
    }
}

private struct DashboardSidebar: View {
    let isShowingScan: Bool
    let onOpen3DView: () -> Void

    var body: some View {
        List {
            Section("Workspace") {

                SidebarItem(
                    title: "Dashboard",
                    systemImage: "square.grid.2x2",
                    isSelected: !isShowingScan,
                    action: {}
                )

                SidebarItem(
                    title: "3D View",
                    systemImage: "view.3d",
                    isSelected: isShowingScan,
                    action: onOpen3DView
                )

                SidebarItem(
                    title: "Map",
                    systemImage: "map",
                    isSelected: false,
                    action: {}
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("CoralFull")
    }
}

private struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isSelected ? .primary : .secondary
        )
    }
}

private struct DashboardContent: View {
    let sites: [CoralSite]
    @Binding var selectedSiteID: String
    let statuses: [String: PipelineStatus]
    let availableTags: [String]
    let onCreateSite: () -> Void
    let onRename: (CoralSite) -> Void
    let onDelete: (CoralSite) -> Void
    let onToggleTag: (CoralSite, String) -> Void
    let onCreateTagForSite: (CoralSite) -> Void

    private let gridColumns = [
        GridItem(.adaptive(minimum: 280, maximum: 560), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("Dashboard")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    CoralInformationCard()

                }

                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        sitesHeader
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sites")
                                .font(.title2)
                                .fontWeight(.semibold)
                            createSiteButton
                        }
                    }

                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(sites) { site in
                            SiteCard(
                                site: site,
                                isSelected: selectedSiteID == site.id,
                                status: statuses[site.id],
                                onSelect: {
                                    withAnimation(.snappy) {
                                        selectedSiteID = site.id
                                    }
                                },
                                onRename: { onRename(site) },
                                onDelete: { onDelete(site) },
                                availableTags: availableTags,
                                onToggleTag: { onToggleTag(site, $0) },
                                onCreateTag: { onCreateTagForSite(site) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 1500, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
    }

    private var sitesHeader: some View {
        HStack {
            Text("Sites")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            createSiteButton
        }
    }

    private var createSiteButton: some View {
        Button(action: onCreateSite) {
            Label("Create site from photos", systemImage: "plus.circle.fill")
                .font(.body.weight(.medium))
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .help("Select a folder or photos to build a new 3D survey site")
    }
}

private struct CoralInformationCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coral Health Information")
                .font(.title3.weight(.semibold))

            Text("Information about the coral health will only be available after uploading photos / videos.")
            Text("Click on each of the site to get an overview of the coral’s health at each of the sites.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

private struct SiteCard: View {
    let site: CoralSite
    let isSelected: Bool
    let status: PipelineStatus?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let availableTags: [String]
    let onToggleTag: (String) -> Void
    let onCreateTag: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 8) {
                Text(site.name)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    PhotoCountBadge(
                        photoCount: site.photoCount
                    )

                    if let tag = site.tags.first {
                        SiteTagBadge(tag: tag)
                        if site.tags.count > 1 {
                            Text("+\(site.tags.count - 1)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    if let state = site.uploadedState {
                        switch state {
                        case .ready:
                            PriorityBadge(priority: site.priority)
                        default:
                            UploadedStateBadge(state: state, status: status)
                        }
                    } else {
                        PriorityBadge(
                            priority: site.priority
                        )
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.background, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("Rename", systemImage: "pencil", action: onRename)
                Divider()
                Menu("Edit Tags", systemImage: "tag") {
                    if availableTags.isEmpty {
                        Text("No tags yet")
                    } else {
                        ForEach(availableTags, id: \.self) { tag in
                            Button {
                                onToggleTag(tag)
                            } label: {
                                HStack {
                                    Text(tag)
                                    if site.tags.contains(tag) {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Create Tag…", systemImage: "plus", action: onCreateTag)
                }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .controlSize(.regular)
            .help("Site actions")
            .padding(18)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(site.name), \(site.photoCount) photos\(site.has3DScan ? ", 3D scan available" : "")")
    }

    @ViewBuilder
    private var cover: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    if let coverImage = site.coverImage {
                        Image(nsImage: coverImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !site.imageName.isEmpty {
                        Image(site.imageName)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LinearGradient(
                            colors: [Color.teal.opacity(0.35), Color.blue.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        VStack(spacing: 8) {
                            if case .processing = site.uploadedState {
                                ProgressView()
                                    .controlSize(.small)
                                if let stage = status?.runningStage {
                                    Text(stage.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Image(systemName: "photo.stack")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("Preview appears after processing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 12))
    }
}

private struct SiteRenameSheet: View {
    let site: CoralSite
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(site: CoralSite, onSave: @escaping (String) -> Void) {
        self.site = site
        self.onSave = onSave
        _name = State(initialValue: site.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename site")
                .font(.title3.weight(.semibold))
            TextField("Site name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct TagCreationSheet: View {
    let existingTags: [String]
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        existingTags.contains { $0.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create tag")
                .font(.title3.weight(.semibold))
            Text("Use tags to organize sites, then select one from the Sites menu to filter the dashboard.")
                .foregroundStyle(.secondary)
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isDuplicate)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isDuplicate else { return }
        onCreate(trimmedName)
        dismiss()
    }
}

@MainActor
private final class SiteCardPreferences: ObservableObject {
    @Published private(set) var nameOverrides: [String: String]
    @Published private(set) var hiddenBuiltInSiteIDs: Set<String>

    private static let namesKey = "coralfull.site-card-name-overrides"
    private static let hiddenIDsKey = "coralfull.hidden-built-in-site-ids"

    init(defaults: UserDefaults = .standard) {
        nameOverrides = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        hiddenBuiltInSiteIDs = Set(defaults.stringArray(forKey: Self.hiddenIDsKey) ?? [])
    }

    func applyingNameOverride(to site: CoralSite) -> CoralSite {
        guard let name = nameOverrides[site.id] else { return site }
        var renamed = site
        renamed.name = name
        return renamed
    }

    func renameBuiltInSite(id: String, to name: String) {
        nameOverrides[id] = name
        UserDefaults.standard.set(nameOverrides, forKey: Self.namesKey)
    }

    func hideBuiltInSite(id: String) {
        hiddenBuiltInSiteIDs.insert(id)
        UserDefaults.standard.set(Array(hiddenBuiltInSiteIDs), forKey: Self.hiddenIDsKey)
    }
}

@MainActor
private final class SiteTagPreferences: ObservableObject {
    @Published private(set) var tags: [String]
    @Published private(set) var tagsBySiteID: [String: [String]]

    private static let tagsKey = "coralfull.site-tags"
    private static let assignmentsKey = "coralfull.site-tag-assignments"

    /// These are the two reference surveys every clean install starts with.
    /// They remain normal, editable tags after the first launch.
    private static let bundledTags = ["Livingseas"]
    private static let bundledTagAssignments = [
        "site-a": ["Livingseas"],
        "site-b": ["Livingseas"]
    ]

    init(defaults: UserDefaults = .standard) {
        tags = defaults.stringArray(forKey: Self.tagsKey) ?? Self.bundledTags
        tagsBySiteID = defaults.dictionary(forKey: Self.assignmentsKey) as? [String: [String]]
            ?? Self.bundledTagAssignments
    }

    func applyingTags(to site: CoralSite) -> CoralSite {
        var tagged = site
        tagged.tags = tagsBySiteID[site.id] ?? []
        return tagged
    }

    @discardableResult
    func create(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let existing = tags.first(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        tags.append(trimmed)
        tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persist()
        return trimmed
    }

    func add(_ tag: String, to siteID: String) {
        guard !tag.isEmpty else { return }
        var siteTags = tagsBySiteID[siteID] ?? []
        guard !siteTags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) else { return }
        siteTags.append(tag)
        siteTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        tagsBySiteID[siteID] = siteTags
        persist()
    }

    func toggle(_ tag: String, for siteID: String) {
        var siteTags = tagsBySiteID[siteID] ?? []
        if let index = siteTags.firstIndex(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            siteTags.remove(at: index)
        } else {
            siteTags.append(tag)
            siteTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        tagsBySiteID[siteID] = siteTags
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(tags, forKey: Self.tagsKey)
        UserDefaults.standard.set(tagsBySiteID, forKey: Self.assignmentsKey)
    }
}

private struct UploadedStateBadge: View {
    let state: UploadedSite.State
    let status: PipelineStatus?

    var body: some View {
        Label(title, systemImage: "circle.fill")
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .fixedSize()
    }

    private var title: String {
        switch state {
        case .importing: "Importing"
        case .processing:
            if let percent = status?.runningStage?.percent {
                "Processing \(Int(percent))%"
            } else {
                "Processing"
            }
        case .ready: "Ready"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        }
    }

    private var color: Color {
        switch state {
        case .importing, .processing: .blue
        case .ready: .green
        case .failed: .red
        case .cancelled, .interrupted: .orange
        }
    }
}

private struct PhotoCountBadge: View {
    let photoCount: Int

    var body: some View {
        Text("\(photoCount) photos")
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.11), in: Capsule())
            .fixedSize()
    }
}

private struct SiteTagBadge: View {
    let tag: String

    var body: some View {
        Label {
            Text(tag)
                .lineLimit(1)
        } icon: {
            Image(systemName: "tag.fill")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.blue.opacity(0.12), in: Capsule())
        .lineLimit(1)
        .layoutPriority(-1)
    }
}

private struct PriorityBadge: View {
    let priority: CoralSite.Priority

    var body: some View {
        Label(priority.title, systemImage: "circle.fill")
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(priority.color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(priority.color.opacity(0.18), in: Capsule())
            .fixedSize()
    }
}

private struct SiteInspector: View {
    let site: CoralSite
    let status: PipelineStatus?
    @Binding var isHealthExpanded: Bool
    let onOpenScan: () -> Void
    let onShowProgress: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    @State private var isPreviewHovered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                previewCard

                Text(site.name)
                    .font(.title3)
                    .fontWeight(.semibold)

                if let state = site.uploadedState {
                    uploadedStateSection(state)
                }

                CoralHealthSection(
                    isExpanded: $isHealthExpanded
                )
            }
            .padding(20)
        }
        .navigationTitle("Site")
    }

    @ViewBuilder
    private func uploadedStateSection(_ state: UploadedSite.State) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .importing, .processing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status?.runningStage?.title ?? "Processing…")
                            .font(.subheadline.weight(.medium))
                        if let detail = status?.runningStage?.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("View progress", action: onShowProgress)
                    .controlSize(.small)
            case .ready:
                EmptyView()
            case .failed(let message):
                Label("Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                HStack {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                    Button("Details", action: onShowProgress)
                        .controlSize(.small)
                    Button("Delete site", role: .destructive, action: onDelete)
                        .controlSize(.small)
                }
            case .cancelled, .interrupted:
                Label(
                    state == .cancelled ? "Processing was cancelled" : "Processing was interrupted",
                    systemImage: "pause.circle"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                HStack {
                    Button("Resume processing", action: onRetry)
                        .controlSize(.small)
                    Button("Delete site", role: .destructive, action: onDelete)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var previewCard: some View {
        let preview = Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack {
                    if let coverImage = site.coverImage {
                        Image(nsImage: coverImage)
                            .resizable()
                            .scaledToFill()
                    } else if !site.imageName.isEmpty {
                        Image(site.imageName)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color.teal.opacity(0.3), Color.blue.opacity(0.16)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "photo.stack")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))

        if site.has3DScan {
            Button(action: onOpenScan) {
                ZStack(alignment: .bottomLeading) {
                    preview

                    Label(
                        site.hasMetashapeMesh || site.uploadedState == .ready
                            ? "Open 3D analysis"
                            : "Open 3D scan",
                        systemImage: "view.3d"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        .ultraThinMaterial,
                        in: Capsule()
                    )
                    .padding(12)
                }
            }
            .buttonStyle(.plain)
        } else {
            ZStack(alignment: .topTrailing) {
                preview

                Text(site.uploadedState == nil ? "3D coming soon" : "Processing")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        .ultraThinMaterial,
                        in: Capsule()
                    )
                    .padding(10)
            }
        }
    }
}

private struct CoralHealthSection: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("Coral Health")
                        .font(.headline)

                    Spacer()

                    Image(
                        systemName: isExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                CoralHealthChart()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

private struct CoralHealthChart: View {
    private let breakdown = [
        CoralHealthSegment(name: "Healthy", value: 10, color: Color(red: 0.78, green: 0.63, blue: 0.98)),
        CoralHealthSegment(name: "Disease", value: 20, color: Color(red: 0.58, green: 0.76, blue: 0.97)),
        CoralHealthSegment(name: "Dead", value: 30, color: Color(red: 0.58, green: 0.80, blue: 0.79)),
        CoralHealthSegment(name: "Others", value: 40, color: Color.secondary.opacity(0.22))
    ]

    var body: some View {
        VStack(spacing: 12) {
            Chart(breakdown) { segment in
                SectorMark(
                    angle: .value("Coral health", segment.value),
                    innerRadius: .ratio(0.60),
                    outerRadius: .inset(4),
                    angularInset: 2
                )
                .cornerRadius(5)
                .foregroundStyle(segment.color)
                .annotation(position: .overlay) {
                    Text("\(segment.value)")
                        .font(.caption)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(segment.name)
                .accessibilityValue("\(segment.value) percent")
            }
            .chartLegend(.hidden)
            .frame(height: 270)

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ForEach(breakdown.prefix(3)) { segment in
                        HealthLegendItem(segment: segment)
                    }
                }

                HealthLegendItem(segment: breakdown[3])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coral health breakdown")
    }
}

private struct HealthLegendItem: View {
    let segment: CoralHealthSegment

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.caption)
                .foregroundStyle(segment.color)
            Text(segment.name)
                .foregroundStyle(.primary)
        }
        .font(.body)
    }
}

private struct CoralHealthSegment: Identifiable {
    let name: String
    let value: Int
    let color: Color

    var id: String { name }
}

struct CoralSite: Identifiable, Equatable {
    enum Priority: String, CaseIterable, Identifiable {
        case high
        case medium
        case low

        var title: String {
            switch self {
            case .high: "High"
            case .medium: "Medium"
            case .low: "Low"
            }
        }

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .high: .red
            case .medium: .orange
            case .low: .green
            }
        }

        var rank: Int {
            switch self {
            case .high: 0
            case .medium: 1
            case .low: 2
            }
        }
    }

    let id: String
    var name: String
    let photoCount: Int
    let priority: Priority
    let imageName: String
    var splatFileName: String? = nil
    var meshFileName: String? = nil
    var uploadedState: UploadedSite.State? = nil
    var coverImage: NSImage? = nil
    var tags: [String] = []

    var hasSplatScan: Bool { splatFileName != nil }
    var hasMetashapeMesh: Bool { meshFileName != nil }
    var has3DScan: Bool { hasSplatScan || hasMetashapeMesh || uploadedState == .ready }
}

let builtInSites = [
    CoralSite(
        id: "site-a",
        name: "Main Reef Structure",
        photoCount: 129,
        priority: .high,
        imageName: "main_reef_struct_cover",
        meshFileName: "site_b_metashape_mesh.ply"
    ),
    CoralSite(
        id: "site-b",
        name: "Reef Star Patch #1",
        photoCount: 26,
        priority: .medium,
        imageName: "SiteB",
        meshFileName: "site_b_metashape_mesh.ply"
    )
]

#Preview {
    ContentView()
        .frame(width: 1_600, height: 1_050)
}
