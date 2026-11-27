import SwiftUI

/// Shared bounds for the iPad and Mac player, measured inside system safe areas.
struct NowPlayingSplitGeometry: Equatable {
    let size: CGSize
    let reservedLeftHeight: CGFloat
    /// The iPhone's landscape height is scarce, so it keeps the shared split
    /// rules but sits closer to its wider handle.
    var handleWidth: CGFloat = Self.handleWidth
    var handleToContentSpacing: CGFloat = Self.handleToContentSpacing
    /// Side margin used while the cover is limited by width. The iPhone uses
    /// a smaller one so its cover fills the short landscape height.
    var preferredHorizontalInset: CGFloat? = nil
    /// Set by `NowPlayingSplitColumnPlan`, which solves the inset together
    /// with the cover and control sizes.
    var fixedHorizontalInset: CGFloat? = nil

    static let handleWidth: CGFloat = 44
    static let handleHeight: CGFloat = 5
    static let handleToContentSpacing: CGFloat = 32
    static func verticalInset(height: CGFloat) -> CGFloat {
        8
    }
    var verticalInset: CGFloat { Self.verticalInset(height: size.height) }
    var top: CGFloat { verticalInset + Self.handleHeight + handleToContentSpacing }
    var contentHeight: CGFloat { max(0, size.height - top - verticalInset) }
    // The shared visual handle is centered; its leading edge is the divider.
    var halfWidth: CGFloat { max(0, (size.width - handleWidth) * 0.5) }
    var horizontalInset: CGFloat {
        if let fixedHorizontalInset { return min(halfWidth * 0.5, fixedHorizontalInset) }
        let preferred = preferredHorizontalInset ?? min(72, max(24, size.width * 0.05))
        // Increase the equal side margins when a short viewport limits the square cover.
        let availableCoverHeight = max(0, contentHeight - reservedLeftHeight)
        return min(halfWidth * 0.5, max(preferred, (halfWidth - availableCoverHeight) * 0.5))
    }
    var playerWidth: CGFloat { max(0, halfWidth - horizontalInset * 2) }
    var panelWidth: CGFloat { max(0, size.width - halfWidth - horizontalInset) }
}

/// Left column of the iPad and Mac split player, solved for the whole
/// viewport instead of only sizing the cover.
///
/// The cover, controls and gaps scale together, so a tall 4:3 iPad or a
/// tall external display does not leave one large hole above the footer:
/// 1. The cover takes the larger of the width or height limit. When width
///    limits it and height is left over, the side margins shrink toward
///    `minimumInset` so the cover grows into that height.
/// 2. Control heights, glyphs and metadata text scale with the cover.
/// 3. The rest of the height is shared between the inner gaps (capped) and
///    equal space above and below the cover and controls, which centers
///    them between the handle and the footer.
/// 4. On short Mac windows the volume row goes away before the cover
///    becomes too small (macOS keeps its system volume control).
struct NowPlayingSplitColumnPlan: Equatable {
    // Base sizes at scale 1, measured from Apple Music's iPad player.
    static let referenceCover: CGFloat = 420
    static let minimumScale: CGFloat = 0.9
    static let maximumScale: CGFloat = 1.2
    static let baseMetadataHeight: CGFloat = 56
    static let baseProgressHeight: CGFloat = 52
    static let baseTransportHeight: CGFloat = 64
    static let baseVolumeHeight: CGFloat = 32
    static let baseArtworkGap: CGFloat = 32
    static let baseMetadataGap: CGFloat = 12
    static let baseProgressGap: CGFloat = 12
    static let baseTransportGap: CGFloat = 25
    static let footerHeight: CGFloat = 44
    static let minimumFooterGap: CGFloat = 16
    /// Leftover height kept before the margins start shrinking to grow the cover.
    static let comfortableSurplus: CGFloat = 40
    /// Share of the leftover height the inner gaps may take, and their cap.
    static let gapSurplusShare: CGFloat = 0.35
    static let maximumGapGrowth: CGFloat = 0.5
    static let volumeHidingCover: CGFloat = 260

    let geometry: NowPlayingSplitGeometry
    let coverSize: CGFloat
    let scale: CGFloat
    let metadataHeight: CGFloat
    let progressHeight: CGFloat
    let transportHeight: CGFloat
    let volumeHeight: CGFloat
    let artworkGap: CGFloat
    let metadataGap: CGFloat
    let progressGap: CGFloat
    let transportGap: CGFloat
    let topPadding: CGFloat
    let footerGap: CGFloat
    let showsVolume: Bool

    var footerHeight: CGFloat { Self.footerHeight }
    var horizontalInset: CGFloat { geometry.horizontalInset }
    var controlsWidth: CGFloat { coverSize }
    /// Cover plus controls, without the padding above and the footer below.
    var blockHeight: CGFloat {
        coverSize + artworkGap + metadataHeight + metadataGap + progressHeight + progressGap
            + transportHeight + (showsVolume ? transportGap + volumeHeight : 0)
    }
    var totalHeight: CGFloat { topPadding + blockHeight + footerGap + footerHeight }

    /// - Parameters:
    ///   - metadataHeight: the metadata row height at scale 1, including Dynamic Type.
    ///   - allowsHidingVolume: true where the system provides another volume control.
    init(size: CGSize, metadataHeight: CGFloat = Self.baseMetadataHeight,
         allowsHidingVolume: Bool = false) {
        let base = NowPlayingSplitGeometry(size: size, reservedLeftHeight: 0)
        let content = base.contentHeight
        let half = base.halfWidth
        let preferredInset = min(72, max(24, size.width * 0.05))
        let minimumInset = min(preferredInset, max(32, size.width * 0.03))

        func stack(_ s: CGFloat, volume: Bool) -> CGFloat {
            let rows = metadataHeight + Self.baseProgressHeight + Self.baseTransportHeight
                + (volume ? Self.baseVolumeHeight : 0)
            let gaps = Self.baseArtworkGap + Self.baseMetadataGap + Self.baseProgressGap
                + (volume ? Self.baseTransportGap : 0)
            return (rows + gaps) * s + Self.minimumFooterGap + Self.footerHeight
        }
        func clampScale(_ cover: CGFloat) -> CGFloat {
            min(Self.maximumScale, max(Self.minimumScale, cover / Self.referenceCover))
        }
        func cover(scale s: CGFloat, volume: Bool) -> CGFloat {
            let heightLimit = content - stack(s, volume: volume)
            let preferred = min(half - preferredInset * 2, heightLimit)
            // Grow into the leftover height beyond a comfortable margin.
            let growth = max(0, heightLimit - preferred - Self.comfortableSurplus)
            let widest = half - minimumInset * 2
            return max(0, min(widest, heightLimit, preferred + growth))
        }
        func solve(volume: Bool) -> (cover: CGFloat, scale: CGFloat) {
            // Cover and scale depend on each other; the loop contracts quickly
            // because one point of scale costs well under one point of cover.
            var s: CGFloat = 1
            var c: CGFloat = 0
            for _ in 0..<8 {
                c = cover(scale: s, volume: volume)
                s = clampScale(c)
            }
            return (cover(scale: s, volume: volume), s)
        }

        var showsVolume = true
        var solved = solve(volume: true)
        if allowsHidingVolume && solved.cover < Self.volumeHidingCover {
            showsVolume = false
            solved = solve(volume: false)
        }
        let s = solved.scale
        let coverSize = solved.cover
        let surplus = max(0, content - coverSize - stack(s, volume: showsVolume))
        let baseGaps = (Self.baseArtworkGap + Self.baseMetadataGap + Self.baseProgressGap
            + (showsVolume ? Self.baseTransportGap : 0)) * s
        let gapGrowth = baseGaps > 0
            ? min(surplus * Self.gapSurplusShare, baseGaps * Self.maximumGapGrowth) / baseGaps : 0
        let gapScale = s * (1 + gapGrowth)
        let remaining = surplus - baseGaps * gapGrowth

        self.geometry = NowPlayingSplitGeometry(
            size: size, reservedLeftHeight: 0,
            fixedHorizontalInset: max(minimumInset, (half - coverSize) * 0.5))
        self.coverSize = coverSize
        self.scale = s
        self.metadataHeight = metadataHeight * s
        self.progressHeight = Self.baseProgressHeight * s
        self.transportHeight = Self.baseTransportHeight * s
        self.volumeHeight = showsVolume ? Self.baseVolumeHeight * s : 0
        self.artworkGap = Self.baseArtworkGap * gapScale
        self.metadataGap = Self.baseMetadataGap * gapScale
        self.progressGap = Self.baseProgressGap * gapScale
        self.transportGap = showsVolume ? Self.baseTransportGap * gapScale : 0
        self.topPadding = remaining * 0.5
        self.footerGap = Self.minimumFooterGap + remaining * 0.5
        self.showsVolume = showsVolume
    }
}

private struct NowPlayingFlushPanelEdgesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var nowPlayingFlushPanelEdges: Bool {
        get { self[NowPlayingFlushPanelEdgesKey.self] }
        set { self[NowPlayingFlushPanelEdgesKey.self] = newValue }
    }
}
