//
//  ContentView.swift
//  coralfull
//
//
import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @State private var selectedSite = sites[0]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .priority
    @State private var isHealthExpanded = true
    @State private var presentedScan: CoralSite?
    
    private var filteredSites: [CoralSite] {
        let matches = sites.filter {
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
            if let presentedScan {
                ReefScanView(site: presentedScan) {
                    withAnimation(.snappy) {
                        self.presentedScan = nil
                    }
                }
            }
            else {
                dashboardView
            }
        }
        .frame(minWidth: 1_260, minHeight: 760)
        .preferredColorScheme(.light)
        .animation(.snappy, value: presentedScan?.id)
    }
    
    private func openSelectedScan() {
        let scanSite = selectedSite.hasSplatScan
        ? selectedSite
        : sites.first(where: \.hasSplatScan)
        
        guard let scanSite else { return }
        
        withAnimation(.snappy) {
            presentedScan = scanSite
        }
    }
    
    @ViewBuilder
    private var dashboardView: some View {
        NavigationSplitView {
            
            // MARK: Sidebar
            DashboardSidebar(
                isShowingScan: false,
                onOpen3DView: openSelectedScan
            )
        } content: {
            
            // MARK: Content
            DashboardContent(
                sites: filteredSites,
                selectedSite: $selectedSite
            )
            
            
        } detail: { SiteInspector(
            site: selectedSite,
            isHealthExpanded: $isHealthExpanded,
            onOpenScan: openSelectedScan
        )
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                DashboardToolbar(
                    searchText: $searchText,
                    sortOrder: $sortOrder,
                    isHealthExpanded: $isHealthExpanded
                )
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search sites"
        )
    }
}

private struct DashboardToolbar: View {
    @Binding var searchText: String
    @Binding var sortOrder: SortOrder
    @Binding var isHealthExpanded: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            
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
//            Button {
//                withAnimation(.snappy) {
//                    isHealthExpanded.toggle()
//                }
//            } label: {
//                Image(systemName: "info.circle")
//            }
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
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isSelected ? .primary : .secondary
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            isSelected
            ? Color.secondary.opacity(0.12)
            : .clear,
            in: .rect(cornerRadius: 10)
        )
    }
}

private struct DashboardContent: View {
    let sites: [CoralSite]
    @Binding var selectedSite: CoralSite
    
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
                    Text("Sites")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 20) {
                        ForEach(sites) { site in
                            Button {
                                withAnimation(.snappy) {
                                    selectedSite = site
                                }
                            } label: {
                                SiteCard(site: site, isSelected: selectedSite.id == site.id)
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
//        .padding(14)
    }
}

private struct SiteCard: View {
    let site: CoralSite
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(site.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity,minHeight: 180, maxHeight: 180)
            //                .aspectRatio(1.82, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 8) {
                Text(site.name)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack {
                    PhotoCountBadge(
                        photoCount: site.photoCount
                    )
                    
                    PriorityBadge(
                        priority: site.priority
                    )
                    
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
        //        .contentShape(.rect(cornerRadius: 25))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(site.name), \(site.photoCount) photos, \(site.priority.title) priority\(site.hasSplatScan ? ", 3D scan available" : "")")
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
    @Binding var isHealthExpanded: Bool
    let onOpenScan: () -> Void
    
    @State private var isPreviewHovered = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                
                previewCard
                
                Text(site.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                
                CoralHealthSection(
                    isExpanded: $isHealthExpanded
                )
            }
            .padding(20)
        }
        .navigationTitle("Site")
    }
    
    @ViewBuilder
    private var previewCard: some View {
        let preview = Image(site.imageName)
            .resizable()
            .scaledToFill()
            .frame(
                maxWidth: .infinity,
                minHeight: 220,
                maxHeight: 220
            )
            .clipped()
            .clipShape(
                RoundedRectangle(cornerRadius: 12)
            )
        
        if site.hasSplatScan {
            Button(action: onOpenScan) {
                ZStack(alignment: .bottomLeading) {
                    preview
                    
                    Label(
                        "Open 3D scan",
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
                
                Text("3D coming soon")
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
        CoralHealthSegment(name: "Healthy", value: 90, color: .green),
        CoralHealthSegment(name: "Unhealthy", value: 10, color: .red),
//        CoralHealthSegment(name: "Dead", value: 30, color: Color(red: 0.58, green: 0.80, blue: 0.79)),
//        CoralHealthSegment(name: "Others", value: 40, color: Color.secondary.opacity(0.22))
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
                
//                HealthLegendItem(segment: breakdown[1])
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
    
    var hasSplatScan: Bool { splatFileName != nil }
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

private let sites = [
    CoralSite(
        id: "site-a",
        name: "Main Reef Structure",
        photoCount: 129,
        priority: .high,
        imageName: "main_reef_struct_cover",
        splatFileName: "reef_struct_orient_proper_cleaned.ply"
    ),
    CoralSite(id: "site-b", name: "Site B", photoCount: 20, priority: .medium, imageName: "SiteB"),
    CoralSite(id: "site-c", name: "Site C", photoCount: 40, priority: .low, imageName: "SiteC")
]

#Preview {
    ContentView()
        .frame(width: 1_600, height: 1_050)
}
