import Foundation
import Testing
@testable import CodaCore

@Suite("Now Playing Split Column Plan Tests")
struct NowPlayingSplitColumnPlanTests {
    struct Viewport {
        let name: String
        let group: String
        let size: CGSize
        var hidesVolume = false
    }

    /// iPad sizes are landscape points inside the safe area; Mac sizes are
    /// full-window content on common built-in and external displays.
    static let viewports: [Viewport] = [
        .init(name: "iPad 9.7\" (1024×768)", group: "iPad", size: .init(width: 1024, height: 748)),
        .init(name: "iPad 9th (1080×810)", group: "iPad", size: .init(width: 1080, height: 790)),
        .init(name: "iPad Pro 10.5\" (1112×834)", group: "iPad", size: .init(width: 1112, height: 814)),
        .init(name: "iPad mini 6 (1133×744)", group: "iPad", size: .init(width: 1133, height: 700)),
        .init(name: "iPad 10th / Air 11\" (1180×820)", group: "iPad", size: .init(width: 1180, height: 776)),
        .init(name: "iPad Pro 11\" (1210×834)", group: "iPad", size: .init(width: 1210, height: 790)),
        .init(name: "iPad Air 13\" (1366×1024)", group: "iPad", size: .init(width: 1366, height: 980)),
        .init(name: "iPad Pro 13\" (1376×1032)", group: "iPad", size: .init(width: 1376, height: 988)),
        .init(name: "Mac 16:10 1440×900", group: "Mac", size: .init(width: 1440, height: 900), hidesVolume: true),
        .init(name: "MacBook Pro 14\" 1512×982", group: "Mac", size: .init(width: 1512, height: 950), hidesVolume: true),
        .init(name: "MacBook Pro 16\" 1728×1117", group: "Mac", size: .init(width: 1728, height: 1085), hidesVolume: true),
        .init(name: "16:9 1920×1080", group: "Mac", size: .init(width: 1920, height: 1050), hidesVolume: true),
        .init(name: "16:9 2560×1440", group: "Mac", size: .init(width: 2560, height: 1410), hidesVolume: true),
        .init(name: "21:9 2560×1080", group: "Mac", size: .init(width: 2560, height: 1050), hidesVolume: true),
        .init(name: "21:9 3440×1440", group: "Mac", size: .init(width: 3440, height: 1410), hidesVolume: true),
        .init(name: "32:9 3840×1080", group: "Mac", size: .init(width: 3840, height: 1050), hidesVolume: true),
        .init(name: "3:2 1500×1000", group: "Mac", size: .init(width: 1500, height: 970), hidesVolume: true),
        .init(name: "4:3 1600×1200", group: "Mac", size: .init(width: 1600, height: 1170), hidesVolume: true),
        .init(name: "5:4 1280×1024", group: "Mac", size: .init(width: 1280, height: 994), hidesVolume: true),
        .init(name: "竖屏 1440×2560", group: "Mac", size: .init(width: 1440, height: 2530), hidesVolume: true),
        .init(name: "矮窗口 1280×640", group: "Mac", size: .init(width: 1280, height: 640), hidesVolume: true),
        .init(name: "矮窗口 1200×520", group: "Mac", size: .init(width: 1200, height: 520), hidesVolume: true),
    ]

    @Test(arguments: viewports.map(\.name))
    func columnFillsViewport(name: String) {
        let viewport = Self.viewports.first { $0.name == name }!
        let plan = NowPlayingSplitColumnPlan(size: viewport.size, allowsHidingVolume: viewport.hidesVolume)
        let geometry = plan.geometry
        #expect(plan.coverSize > 0)
        // The cover and controls fit between the side margins.
        #expect(plan.coverSize + plan.horizontalInset * 2 <= geometry.halfWidth + 0.5)
        #expect(plan.horizontalInset >= 32 - 0.5)
        // The column uses the full height, with no overflow.
        #expect(abs(plan.totalHeight - geometry.contentHeight) < 1)
        // Leftover height is split evenly above and below.
        #expect(abs(plan.topPadding - (plan.footerGap - NowPlayingSplitColumnPlan.minimumFooterGap)) < 0.5)
        #expect((NowPlayingSplitColumnPlan.minimumScale...NowPlayingSplitColumnPlan.maximumScale).contains(plan.scale))
    }

    @Test func tallIPadUsesHeightInsteadOfLeavingAGap() {
        let size = CGSize(width: 1366, height: 980)
        let plan = NowPlayingSplitColumnPlan(size: size)
        let legacy = Self.legacy(size: size)
        #expect(legacy.footerGap > 60)
        #expect(plan.footerGap < 30)
        #expect(plan.coverSize >= legacy.cover - 1)
        #expect(plan.scale > 1.1)
    }

    @Test func tallMacWindowGrowsCover() {
        let size = CGSize(width: 1600, height: 1170)
        let plan = NowPlayingSplitColumnPlan(size: size, allowsHidingVolume: true)
        #expect(plan.coverSize > Self.legacy(size: size).cover)
        #expect(plan.footerGap < 40)
    }

    @Test func shortMacWindowDropsVolumeBeforeShrinkingCoverTooFar() {
        let plan = NowPlayingSplitColumnPlan(size: .init(width: 1200, height: 520), allowsHidingVolume: true)
        #expect(!plan.showsVolume)
        let iPad = NowPlayingSplitColumnPlan(size: .init(width: 1200, height: 520))
        #expect(iPad.showsVolume)
    }

    /// The previous layout: fixed controls and one spacer above the footer.
    static func legacy(size: CGSize) -> (geometry: NowPlayingSplitGeometry, cover: CGFloat, footerGap: CGFloat) {
        let reserved: CGFloat = 32 + 56 + 12 + 52 + 12 + 64 + 25 + 32 + 2 + 44
        let geometry = NowPlayingSplitGeometry(size: size, reservedLeftHeight: reserved)
        let cover = geometry.playerWidth
        let used = cover + reserved - 2
        return (geometry, cover, max(2, geometry.contentHeight - used))
    }

    /// Writes old and new layouts for every viewport when
    /// CODA_SPLIT_PLAN_DUMP names an output file.
    @Test func dumpLayouts() throws {
        guard let path = ProcessInfo.processInfo.environment["CODA_SPLIT_PLAN_DUMP"] else { return }
        var rows: [[String: Any]] = []
        for viewport in Self.viewports {
            let plan = NowPlayingSplitColumnPlan(size: viewport.size, allowsHidingVolume: viewport.hidesVolume)
            let old = Self.legacy(size: viewport.size)
            let g = plan.geometry
            rows.append([
                "name": viewport.name, "group": viewport.group,
                "width": viewport.size.width, "height": viewport.size.height,
                "top": g.top, "contentHeight": g.contentHeight, "halfWidth": g.halfWidth,
                "handleWidth": g.handleWidth,
                "new": [
                    "inset": plan.horizontalInset, "panelWidth": g.panelWidth,
                    "cover": plan.coverSize, "scale": plan.scale, "topPadding": plan.topPadding,
                    "artworkGap": plan.artworkGap, "metadataHeight": plan.metadataHeight,
                    "metadataGap": plan.metadataGap, "progressHeight": plan.progressHeight,
                    "progressGap": plan.progressGap, "transportHeight": plan.transportHeight,
                    "transportGap": plan.transportGap, "volumeHeight": plan.volumeHeight,
                    "showsVolume": plan.showsVolume, "footerGap": plan.footerGap,
                    "footerHeight": plan.footerHeight,
                ],
                "old": [
                    "inset": old.geometry.horizontalInset, "panelWidth": old.geometry.panelWidth,
                    "cover": old.cover, "scale": 1, "topPadding": 0,
                    "artworkGap": 32, "metadataHeight": 56, "metadataGap": 12,
                    "progressHeight": 52, "progressGap": 12, "transportHeight": 64,
                    "transportGap": 25, "volumeHeight": 32, "showsVolume": true,
                    "footerGap": old.footerGap, "footerHeight": 44,
                ],
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
