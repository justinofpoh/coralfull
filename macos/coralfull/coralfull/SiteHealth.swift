//
//  SiteHealth.swift
//  coralfull
//
//  Coral health derived from a site's analysis manifest.
//
//  The dashboard donut previously rendered four fixed numbers -- 10/20/30/40 --
//  that were never read from anything. In a reef health tool that reads as a
//  measurement, so it is computed here or not shown at all.
//

import Foundation

struct SiteHealth: Equatable {
    /// Labelled mesh vertices, from AnalysisSequence.Labels3D.counts.
    let healthy: Int
    let unhealthy: Int
    /// Share of mesh vertices that received a label at all.
    let labeledVertexPercent: Double?
    /// Mean of the per-frame percentages, for scans with no 3D labels.
    let frameHealthyPercent: Double?
    let frameUnhealthyPercent: Double?

    var labelled: Int { healthy + unhealthy }
    var hasVertexLabels: Bool { labelled > 0 }

    var healthyPercent: Double {
        if hasVertexLabels { return Double(healthy) / Double(labelled) * 100 }
        return frameHealthyPercent ?? 0
    }

    var unhealthyPercent: Double {
        if hasVertexLabels { return Double(unhealthy) / Double(labelled) * 100 }
        return frameUnhealthyPercent ?? 0
    }

    /// True when the manifest carried nothing to report -- the bundled
    /// reference scan is one of these: it has no labels3d block at all.
    var isEmpty: Bool {
        !hasVertexLabels && frameHealthyPercent == nil
    }

    init(sequence: AnalysisSequence) {
        let counts = sequence.labels3d?.counts ?? [:]
        healthy = counts["healthy"] ?? 0
        unhealthy = counts["unhealthy"] ?? 0
        labeledVertexPercent = sequence.labels3d?.labeledVertexPercent

        let frames = sequence.frames
        if frames.isEmpty {
            frameHealthyPercent = nil
            frameUnhealthyPercent = nil
        } else {
            let count = Double(frames.count)
            frameHealthyPercent = frames.reduce(0) { $0 + $1.healthyPercent } / count
            frameUnhealthyPercent = frames.reduce(0) { $0 + $1.unhealthyPercent } / count
        }
    }
}
