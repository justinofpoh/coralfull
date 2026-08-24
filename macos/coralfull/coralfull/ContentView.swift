//
//  ContentView.swift
//  coralfull
//
//
import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @StateObject private var store = SiteStore()
    @State private var selectedSiteID: String = builtInSites[0].id
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .priority
    @State private var isHealthExpanded = true
    @State private var presentedScan: CoralSite?
    @State private var creationSelection: ImportSelection?
    @State private var processingSheetSiteID: ProcessingSheetTarget?
    @State private var importErrorMessage: String?

    private var allSites: [CoralSite] {
        builtInSites + store.sites.map { uploaded in
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
    }

    private var selectedSite: CoralSite {
        allSites.first { $0.id == selectedSiteID } ?? allSites[0]
    }

    private var filteredSites: [CoralSite] {
        let matches = allSites.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
        }

        switch sortOrder {
        case .priority:
            return matches.sorted { $0.priority.rank < $1.priority.rank }
        case .name:
            return matches.sorted { $0.name < $1.name }
        case .photos:
            return matches.sorted { $0.photoCount > $1.photoCount }
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
                                sortOrder: $sortOrder,
                                isHealthExpanded: $isHealthExpanded,
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
        .frame(minWidth: 1_260, minHeight: 760)
        .preferredColorScheme(presentedScan == nil ? .light : .dark)
        .overlay {
            if let presentedScan {
                scanView(for: presentedScan)
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
            .frame(width: 640, height: 620)
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

    private func openUploadedAnalysis(siteID: String) {
        guard let site = allSites.first(where: { $0.id == siteID }) else { return }
        selectedSiteID = siteID
        withAnimation(.snappy) {
            presentedScan = site
        }
    }

    private func openSelectedScan() {
        let scanSite = selectedSite.has3DScan
        ? selectedSite
        : allSites.first(where: \.has3DScan)

        guard let scanSite else { return }

        withAnimation(.snappy) {
            presentedScan = scanSite
        }
    }

    @ViewBuilder
    private func scanView(for site: CoralSite) -> some View {
        let close = {
            withAnimation(.snappy) {
                presentedScan = nil
            }
        }
        if site.uploadedState != nil {
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
                onCreateSite: presentPhotoPicker
            )


        } detail: { SiteInspector(
            site: selectedSite,
            status: store.statuses[selectedSite.id],
            isHealthExpanded: $isHealthExpanded,
            onOpenScan: openSelectedScan,
            onShowProgress: { processingSheetSiteID = ProcessingSheetTarget(id: selectedSite.id) },
            onRetry: { store.retry(siteID: selectedSite.id) },
            onDelete: {
                let siteID = selectedSite.id
                store.delete(siteID: siteID)
                selectedSiteID = builtInSites[0].id
            }
        )
        }
        .navigationSplitViewStyle(.balanced)
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
    @Binding var sortOrder: SortOrder
    @Binding var isHealthExpanded: Bool
    let onCreateSite: () -> Void

    var body: some View {
        HStack(spacing: 4) {

            // Create site
            Button(action: onCreateSite) {
                Label("Create site", systemImage: "plus")
            }
            .help("Create a new site from survey photos")

            // Sites
            Menu {
                Button {
                    searchText = ""
                } label: {
                    Label("All Sites", systemImage: "square.grid.2x2")
                }

                Divider()

                Button("Main Reef Structure") {
                    searchText = "Main Reef Structure"
                }

                Button("Site B") {
                    searchText = "Site B"
                }

                Button("Site C") {
                    searchText = "Site C"
                }
            } label: {
                Text("Sites")
            }
            .menuStyle(.borderlessButton)

            // Sort
            Menu {
                ForEach(SortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Text(order.title)

                            if sortOrder == order {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(sortOrder.title)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)

            // Health information
            Button {
                withAnimation(.snappy) {
                    isHealthExpanded.toggle()
                }
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show coral health details")
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
    let onCreateSite: () -> Void

    private let gridColumns = [
        GridItem(.flexible(minimum: 280), spacing: 16),
        GridItem(.flexible(minimum: 280), spacing: 16)
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
                    HStack {
                        Text("Sites")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Spacer()

                        Button(action: onCreateSite) {
                            Label("Create site from photos", systemImage: "plus.circle.fill")
                                .font(.body.weight(.medium))
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .help("Select a folder or photos to build a new 3D survey site")
                    }

                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                        ForEach(sites) { site in
                            Button {
                                withAnimation(.snappy) {
                                    selectedSiteID = site.id
                                }
                            } label: {
                                SiteCard(
                                    site: site,
                                    isSelected: selectedSiteID == site.id,
                                    status: statuses[site.id]
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 1500, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
                .clipShape(.rect(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 8) {
                Text(site.name)
                    .font(.headline)
                    .lineLimit(2)

                HStack {
                    PhotoCountBadge(
                        photoCount: site.photoCount
                    )

                    if let state = site.uploadedState {
                        UploadedStateBadge(state: state, status: status)
                    } else {
                        PriorityBadge(
                            priority: site.priority
                        )
                    }

                    Spacer()
                }
            }
        }
        .padding(12)
        .background(.background, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(site.name), \(site.photoCount) photos\(site.has3DScan ? ", 3D scan available" : "")")
    }

    @ViewBuilder
    private var cover: some View {
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
}

private struct UploadedStateBadge: View {
    let state: UploadedSite.State
    let status: PipelineStatus?

    var body: some View {
        Label(title, systemImage: "circle.fill")
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
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
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.11), in: Capsule())
    }
}

private struct PriorityBadge: View {
    let priority: CoralSite.Priority

    var body: some View {
        Label(priority.title, systemImage: "circle.fill")
            .font(.body.weight(.medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(priority.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(priority.color.opacity(0.18), in: Capsule())
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
        let preview = Group {
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
        .frame(
            maxWidth: .infinity,
            minHeight: 220,
            maxHeight: 220
        )
        .clipped()
        .clipShape(
            RoundedRectangle(cornerRadius: 12)
        )

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
    enum Priority: String {
        case high
        case medium
        case low

        var title: String {
            switch self {
            case .high: "High"
            case .medium: "Med"
            case .low: "Low"
            }
        }

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
    let name: String
    let photoCount: Int
    let priority: Priority
    let imageName: String
    var splatFileName: String? = nil
    var meshFileName: String? = nil
    var uploadedState: UploadedSite.State? = nil
    var coverImage: NSImage? = nil

    var hasSplatScan: Bool { splatFileName != nil }
    var hasMetashapeMesh: Bool { meshFileName != nil }
    var has3DScan: Bool { hasSplatScan || hasMetashapeMesh || uploadedState == .ready }
}

private enum SortOrder: CaseIterable, Identifiable {
    case priority
    case name
    case photos

    var id: Self { self }

    var title: String {
        switch self {
        case .priority: "Priority"
        case .name: "Name"
        case .photos: "Photos"
        }
    }
}

let builtInSites = [
    CoralSite(
        id: "site-a",
        name: "Main Reef Structure",
        photoCount: 129,
        priority: .high,
        imageName: "main_reef_struct_cover",
        splatFileName: "reef_struct_orient_proper_cleaned.ply"
    ),
    CoralSite(
        id: "site-b",
        name: "Site B",
        photoCount: 26,
        priority: .medium,
        imageName: "SiteB",
        meshFileName: "site_b_metashape_mesh.ply"
    ),
    CoralSite(id: "site-c", name: "Site C", photoCount: 40, priority: .low, imageName: "SiteC")
]

#Preview {
    ContentView()
        .frame(width: 1_600, height: 1_050)
}
