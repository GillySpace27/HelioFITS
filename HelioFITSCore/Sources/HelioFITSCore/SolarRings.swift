//
//  SolarRings.swift: plane-of-sky radius rings and position-angle spokes (HF-15).
//
//  Platform-neutral geometry in NORMALIZED image coordinates (0...1 across,
//  0...1 down from the top-left), so the Mac canvas and the iOS viewer draw the
//  same lines the same way as the limb circle.
//
//  The radius convention is the coronagraph one: a ring labelled k R_sun joins the
//  directions whose line of sight passes k solar radii from the Sun's centre,
//  D sin(eps) = k R_sun, with eps the angular distance from the Sun's centre
//  (cos eps = cos Tx cos Ty) and D the observer distance. Since
//  sin(rho) = R_sun / D for the Sun's apparent angular radius rho, that is
//
//      sin(eps) = k sin(rho)
//
//  so no DSUN_OBS card is needed when RSUN_OBS / RSUN_ARC gives rho (SolarWCS.rsun
//  is derived from DSUN_OBS when neither is present). Over a small field this
//  is the usual "k times the apparent solar radius"; over PUNCH's 45 degrees it
//  differs from the flat-angle rule by eps / sin(eps), about 11 % at 45 degrees.
//
//  Position angle is measured from solar north (+Ty) through solar east (-Tx), the
//  usual convention. Spokes are drawn every 30 degrees.
//
//  No ring rather than a wrong ring: `make` returns nil when the frame has no solar
//  WCS, no known solar radius, or no ring falls inside the field.
//

import Foundation
import CoreGraphics

public struct SolarRings {

    /// One ring: k solar radii, as polyline pieces (a ring leaves and re-enters
    /// the frame, and a zenithal projection can refuse points on its far side).
    public struct Ring {
        public let k: Double
        public let label: String
        public let elongationDegrees: Double
        public let segments: [[CGPoint]]
        /// A point on the ring inside the frame where its label fits; nil if none is.
        public let labelAt: CGPoint?
    }

    /// One spoke: a radial line from the Sun's centre at a position angle.
    public struct Spoke {
        public let positionAngleDegrees: Double
        public let segments: [[CGPoint]]
        /// The outermost point inside the frame, where its angle label goes.
        public let labelAt: CGPoint?
    }

    public let rings: [Ring]
    public let spokes: [Spoke]

    /// Ring radii offered, in solar radii. Only those that cross the field are used.
    public static let candidateRadii: [Double] =
        [0.5, 1, 1.5, 2, 3, 5, 10, 15, 20, 30, 40, 60, 80, 120, 160, 215]
    public static let maxRings = 6
    public static let spokeStepDegrees = 30.0

    // MARK: pure geometry (unit-tested against astropy)

    /// Angular distance from the Sun's centre, degrees, for helioprojective (Tx, Ty) in arcsec.
    public static func elongationDegrees(tx: Double, ty: Double) -> Double {
        let d2r = Double.pi / 180
        let c = cos(tx / 3600 * d2r) * cos(ty / 3600 * d2r)
        return acos(max(-1, min(1, c))) / d2r
    }

    /// Helioprojective (Tx, Ty) in arcsec at an elongation (degrees) and a position
    /// angle (degrees, from solar north through solar east).
    public static func skyPoint(elongationDegrees eps: Double,
                                positionAngleDegrees pa: Double) -> (tx: Double, ty: Double) {
        let d2r = Double.pi / 180
        let e = eps * d2r
        let b = -pa * d2r                       // bearing toward +Tx (west), the other way round from east
        let ty = asin(max(-1, min(1, sin(e) * cos(b))))
        let tx = atan2(sin(b) * sin(e), cos(e))
        return (tx / d2r * 3600, ty / d2r * 3600)
    }

    /// Elongation (degrees) of the ring k solar radii out, given the Sun's apparent
    /// radius in arcsec; nil when the ring would not fit in front of the observer.
    public static func ringElongationDegrees(k: Double, solarRadiusArcsec rho: Double) -> Double? {
        guard k > 0, rho > 0 else { return nil }
        let s = k * sin(rho / 3600 * Double.pi / 180)
        guard s < 0.9999 else { return nil }
        return asin(s) * 180 / Double.pi
    }

    /// Ring label text: "1 R☉", "0.5 R☉".
    public static func label(k: Double) -> String {
        (k == k.rounded() ? String(Int(k)) : String(k)) + " R☉"
    }

    // MARK: construction

    public static func make(wcs: FITSRenderer.SolarWCS, natW: Int, natH: Int) -> SolarRings? {
        guard wcs.rsun > 0, natW > 0, natH > 0 else { return nil }

        /// FITS pixel (1-based, y up) of a sky point as normalized display coordinates.
        func uv(_ tx: Double, _ ty: Double) -> CGPoint? {
            guard let p = wcs.pixel(tx: tx, ty: ty) else { return nil }
            return CGPoint(x: (p.fx - 0.5) / Double(natW), y: (Double(natH) + 0.5 - p.fy) / Double(natH))
        }
        func inFrame(_ p: CGPoint, margin: Double = 0.02) -> Bool {
            p.x >= margin && p.x <= 1 - margin && p.y >= margin && p.y <= 1 - margin
        }
        /// Group consecutive placeable points into polyline pieces.
        func pieces(_ pts: [CGPoint?]) -> [[CGPoint]] {
            var out: [[CGPoint]] = [], cur: [CGPoint] = []
            for p in pts {
                if let p { cur.append(p) } else { if cur.count > 1 { out.append(cur) }; cur = [] }
            }
            if cur.count > 1 { out.append(cur) }
            return out
        }

        // How far from the Sun's centre does the field reach? Sample a grid of pixels.
        var eMin = Double.infinity, eMax = 0.0
        let n = 16
        for i in 0...n {
            for j in 0...n {
                let fx = 0.5 + Double(natW) * Double(i) / Double(n)
                let fy = 0.5 + Double(natH) * Double(j) / Double(n)
                let (tx, ty) = wcs.hpc(fx, fy)
                guard tx.isFinite, ty.isFinite else { continue }
                let e = elongationDegrees(tx: tx, ty: ty)
                eMin = min(eMin, e); eMax = max(eMax, e)
            }
        }
        guard eMin.isFinite, eMax > 0 else { return nil }

        var chosen: [(k: Double, eps: Double)] = []
        for k in candidateRadii {
            guard let e = ringElongationDegrees(k: k, solarRadiusArcsec: wcs.rsun) else { continue }
            if e >= eMin && e <= eMax { chosen.append((k, e)) }
        }
        guard !chosen.isEmpty else { return nil }
        if chosen.count > maxRings {
            let last = chosen.count - 1
            chosen = (0..<maxRings).map { chosen[Int((Double($0) * Double(last) / Double(maxRings - 1)).rounded())] }
        }

        let labelAngles: [Double] = [135, 225, 45, 315, 180, 90, 0, 270]
        var rings: [Ring] = []
        for (k, eps) in chosen {
            let pts: [CGPoint?] = stride(from: 0.0, through: 360.0, by: 2.0).map { pa in
                let s = skyPoint(elongationDegrees: eps, positionAngleDegrees: pa)
                return uv(s.tx, s.ty)
            }
            let at = labelAngles.lazy.compactMap { pa -> CGPoint? in
                let s = skyPoint(elongationDegrees: eps, positionAngleDegrees: pa)
                return uv(s.tx, s.ty)
            }.first(where: { inFrame($0, margin: 0.05) })
            rings.append(Ring(k: k, label: label(k: k), elongationDegrees: eps,
                              segments: pieces(pts), labelAt: at))
        }

        let reach = chosen.map(\.eps).max() ?? 0
        var spokes: [Spoke] = []
        for pa in stride(from: 0.0, to: 360.0, by: spokeStepDegrees) {
            let steps = 48
            let pts: [CGPoint?] = (0...steps).map { i in
                let s = skyPoint(elongationDegrees: reach * Double(i) / Double(steps), positionAngleDegrees: pa)
                return uv(s.tx, s.ty)
            }
            let at = pts.reversed().compactMap { $0 }.first(where: { inFrame($0, margin: 0.05) })
            spokes.append(Spoke(positionAngleDegrees: pa, segments: pieces(pts), labelAt: at))
        }
        return SolarRings(rings: rings, spokes: spokes)
    }
}
