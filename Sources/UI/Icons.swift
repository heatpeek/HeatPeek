import SwiftUI

/// Icon geometry from the Lucide set (ISC), 24x24 grid, stroke-based.
enum IconShape: String, CaseIterable {
    case power
    case pause
    case play
    case camera
    case video
    case circleDot
    case panelRight
    case chartLine
    case rotateCw
    case flipHorizontal
    case aperture
    case trash
    case bell
    case bellOff
    case circleMinus
    case thermometer
    case cameraOff
    case circleAlert
    case copy
    case check
    case x
    case plus
    case layers
    case ruler
    case scan
    case gridx2
    case radio
    case chevronDown
    case moveHorizontal

    /// Drawing commands in the 24x24 source grid.
    var elements: [IconElement] {
        switch self {
        case .power: return [.path("M12 2v10"), .path("M18.4 6.6a9 9 0 1 1-12.77.04")]
        case .pause: return [.rect("14,3,5,18,1"), .rect("5,3,5,18,1")]
        case .play: return [.path("M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z")]
        case .camera: return [.path("M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z"), .circle("12,13,3")]
        case .video: return [.path("m16 13 5.223 3.482a.5.5 0 0 0 .777-.416V7.87a.5.5 0 0 0-.752-.432L16 10.5"), .rect("2,6,14,12,2")]
        case .circleDot: return [.circle("12,12,1"), .circle("12,12,10")]
        case .panelRight: return [.path("M15 3v18"), .rect("3,3,18,18,2")]
        case .chartLine: return [.path("M3 3v16a2 2 0 0 0 2 2h16"), .path("m19 9-5 5-4-4-3 3")]
        case .rotateCw: return [.path("M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"), .path("M21 3v5h-5")]
        case .flipHorizontal: return [.path("m3 7 5 5-5 5V7"), .path("m21 7-5 5 5 5V7"), .path("M12 20v2"), .path("M12 14v2"), .path("M12 8v2"), .path("M12 2v2")]
        case .aperture: return [.path("m14.31 8 5.74 9.94"), .path("M9.69 8h11.48"), .path("m7.38 12 5.74-9.94"), .path("M9.69 16 3.95 6.06"), .path("M14.31 16H2.83"), .path("m16.62 12-5.74 9.94"), .circle("12,12,10")]
        case .trash: return [.path("M10 11v6"), .path("M14 11v6"), .path("M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"), .path("M3 6h18"), .path("M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2")]
        case .bell: return [.path("M10.268 21a2 2 0 0 0 3.464 0"), .path("M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326")]
        case .bellOff: return [.path("M10.268 21a2 2 0 0 0 3.464 0"), .path("M17 17H4a1 1 0 0 1-.74-1.673C4.59 13.956 6 12.499 6 8a6 6 0 0 1 .258-1.742"), .path("m2 2 20 20"), .path("M8.668 3.01A6 6 0 0 1 18 8c0 2.687.77 4.653 1.707 6.05")]
        case .circleMinus: return [.path("M8 12h8"), .circle("12,12,10")]
        case .thermometer: return [.path("M14 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z")]
        case .cameraOff: return [.path("M14.564 14.558a3 3 0 1 1-4.122-4.121"), .path("m2 2 20 20"), .path("M20 20H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 .819-.175"), .path("M9.695 4.024A2 2 0 0 1 10.004 4h3.993a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v7.344")]
        case .circleAlert: return [.circle("12,12,10"), .line("12,8,12,12"), .line("12,16,12.01,16")]
        case .copy: return [.path("M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"), .rect("8,8,14,14,2")]
        case .check: return [.path("M20 6 9 17l-5-5")]
        case .x: return [.path("M18 6 6 18"), .path("m6 6 12 12")]
        case .plus: return [.path("M5 12h14"), .path("M12 5v14")]
        case .layers: return [.path("M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z"), .path("M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12"), .path("M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17")]
        case .ruler: return [.path("M21.3 15.3a2.4 2.4 0 0 1 0 3.4l-2.6 2.6a2.4 2.4 0 0 1-3.4 0L2.7 8.7a2.41 2.41 0 0 1 0-3.4l2.6-2.6a2.41 2.41 0 0 1 3.4 0Z"), .path("m14.5 12.5 2-2"), .path("m11.5 9.5 2-2"), .path("m8.5 6.5 2-2"), .path("m17.5 15.5 2-2")]
        case .scan: return [.path("M3 7V5a2 2 0 0 1 2-2h2"), .path("M17 3h2a2 2 0 0 1 2 2v2"), .path("M21 17v2a2 2 0 0 1-2 2h-2"), .path("M7 21H5a2 2 0 0 1-2-2v-2")]
        case .gridx2: return [.path("M12 3v18"), .path("M3 12h18"), .rect("3,3,18,18,2")]
        case .radio: return [.path("M16.247 7.761a6 6 0 0 1 0 8.478"), .path("M19.075 4.933a10 10 0 0 1 0 14.134"), .path("M4.925 19.067a10 10 0 0 1 0-14.134"), .path("M7.753 16.239a6 6 0 0 1 0-8.478"), .circle("12,12,2")]
        case .chevronDown: return [.path("m6 9 6 6 6-6")]
        case .moveHorizontal: return [.path("m18 8 4 4-4 4"), .path("M2 12h20"), .path("m6 8-4 4 4 4")]
        }
    }
}

/// One drawing primitive of an icon.
enum IconElement {
    case path(String)
    case circle(String)
    case line(String)
    case rect(String)
    case polyline(String)
    case polygon(String)
}
