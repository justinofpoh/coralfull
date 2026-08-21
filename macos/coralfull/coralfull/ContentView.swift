//
//  ContentView.swift
//  coralfull
//

import AppKit
import Charts
import SwiftUI

struct ContentView: View {
    @State private var selectedSite = sites[0]
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .priority
    @State private var isHealthExpanded = true
    @State private var isSidebarExpanded = true
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
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if isSidebarExpanded {
                    DashboardSidebar(
                        isExpanded: $isSidebarExpanded,
                        isShowingScan: presentedScan != nil,
                        onOpen3DView: openSelectedScan
                    )
                }

                DashboardContent(
                    sites: filteredSites,
                    selectedSite: $selectedSite,
                    maxContentWidth: isSidebarExpanded ? 780 : 1_100,
                    showsDashboardOverview: isSidebarExpanded
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 26)
                .padding(.trailing, 26)

                Divider()

                SiteInspector(
                    site: selectedSite,
                    isHealthExpanded: $isHealthExpanded,
                    onOpenScan: openSelectedScan
                )
                .frame(width: 390)
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
            .padding(.leading, 26)
            .padding(.trailing, 20)

            if presentedScan == nil {
                DashboardToolbar(
                    searchText: $searchText,
                    sortOrder: $sortOrder,
                    isHealthExpanded: $isHealthExpanded
                )
                .padding(.top, 16)
                .padding(.trailing, 16)
            }

            if !isSidebarExpanded {
                CollapsedDashboardHeader(isSidebarExpanded: $isSidebarExpanded)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 1_260, minHeight: 760)
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .background(WindowConfigurator())
        .overlay {
            if let presentedScan {
                ReefScanView(site: presentedScan) {
                    withAnimation(.snappy) {
                        self.presentedScan = nil
                    }
                }
                .transition(.opacity)
            }
        }
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
}

private struct CollapsedDashboardHeader: View {
    @Binding var isSidebarExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            WindowTrafficControls()

            Button {
                withAnimation(.snappy) {
                    isSidebarExpanded = true
                }
            } label: {
                HStack(spacing: 8) {
                    dashboardIcon

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Dashboard")
                            .font(.headline)
                        Text("3 Sites")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Expand Dashboard")
            .accessibilityLabel("Expand Dashboard")

            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.top, 20)
    }

    @ViewBuilder
    private var dashboardIcon: some View {
        if #available(macOS 26.0, *) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(Color.secondary.opacity(0.25)) }
        }
    }
}

private struct DashboardToolbar: View {
    @Binding var searchText: String
    @Binding var sortOrder: SortOrder
    @Binding var isHealthExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu("Sites") {
                Button("All Sites") {
                    searchText = ""
                }
            }
                .controlSize(.small)

            Picker("Sort sites", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)

            Button {
                withAnimation(.snappy) {
                    isHealthExpanded.toggle()
                }
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show coral health details")

            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 135)
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var isExpanded: Bool
    let isShowingScan: Bool
    let onOpen3DView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if isExpanded {
                    WindowTrafficControls()
                }
                Spacer()
                Button {
                    withAnimation(.snappy) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse Dashboard" : "Expand Dashboard")
            }
            .frame(height: 24)
            .padding(.bottom, 16)

            SidebarItem(title: "Dashboard", systemImage: "square.grid.2x2", isSelected: !isShowingScan, isExpanded: isExpanded) {}
            SidebarItem(title: "3D View", systemImage: "view.3d", isSelected: isShowingScan, isExpanded: isExpanded, action: onOpen3DView)
            SidebarItem(title: "Map (coming soon)", systemImage: "map", isSelected: false, isExpanded: isExpanded) {}

            Spacer()
        }
        .padding(20)
        .frame(width: isExpanded ? 320 : 72, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: .rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
        .animation(.snappy, value: isExpanded)
    }
}

private struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                if isExpanded {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .font(.title3.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isExpanded ? 14 : 8)
                .padding(.vertical, 11)
                .background(isSelected ? Color.secondary.opacity(0.12) : .clear, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct DashboardContent: View {
    let sites: [CoralSite]
    @Binding var selectedSite: CoralSite
    let maxContentWidth: CGFloat
    let showsDashboardOverview: Bool

    private let gridColumns = [
        GridItem(.flexible(minimum: 260, maximum: 420), spacing: 16),
        GridItem(.flexible(minimum: 260, maximum: 420), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if showsDashboardOverview {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dashboard")
                            .font(.system(size: 40, weight: .bold))

                        CoralInformationCard()
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Sites")
                        .font(.system(size: 34, weight: .bold))

                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 22) {
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
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(.top, showsDashboardOverview ? 78 : 64)
            .padding(.bottom, 32)
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
        .background(Color.secondary.opacity(0.045), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

private struct SiteCard: View {
    let site: CoralSite
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(site.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .aspectRatio(1.82, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 20))

            HStack(spacing: 7) {
                Text(site.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if site.hasSplatScan {
                    ScanBadge()
                }
                PhotoCountBadge(photoCount: site.photoCount)
                PriorityBadge(priority: site.priority)
            }
        }
        .padding(7)
        .background(.background, in: .rect(cornerRadius: 25))
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: 25))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(site.name), \(site.photoCount) photos, \(site.priority.title) priority\(site.hasSplatScan ? ", 3D scan available" : "")")
    }
}

private struct ScanBadge: View {
    var body: some View {
        Label("3D", systemImage: "view.3d")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.blue, in: Capsule())
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

    private let imageWidth: CGFloat = 358

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                previewCard

                Text(site.name)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Coral Health")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Button {
                        withAnimation(.snappy) {
                            isHealthExpanded.toggle()
                        }
                    } label: {
                        Label("Details", systemImage: isHealthExpanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Coral health details")
                    .accessibilityValue(isHealthExpanded ? "Expanded" : "Collapsed")

                    if isHealthExpanded {
                        CoralHealthChart()
                            .padding(.top, 10)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))

                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .padding(.top, 72)
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        let preview = Image(site.imageName)
            .resizable()
            .scaledToFill()
            .frame(width: imageWidth, height: 236)
            .clipped()
            .clipShape(.rect(cornerRadius: 14))

        if site.hasSplatScan {
            Button(action: onOpenScan) {
                ZStack(alignment: .bottomLeading) {
                    preview
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.black.opacity(isPreviewHovered ? 0.28 : 0.12))
                        }

                    HStack(spacing: 8) {
                        Image(systemName: "view.3d")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Open 3D scan")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                }
                .scaleEffect(isPreviewHovered ? 1.015 : 1)
            }
            .buttonStyle(.plain)
            .onHover { isPreviewHovered = $0 }
            .help("Open the gaussian splat of this reef")
            .accessibilityLabel("Open 3D scan of \(site.name)")
            .animation(.snappy(duration: 0.22), value: isPreviewHovered)
        } else {
            ZStack(alignment: .topTrailing) {
                preview

                Text("3D coming soon")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
        }
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
