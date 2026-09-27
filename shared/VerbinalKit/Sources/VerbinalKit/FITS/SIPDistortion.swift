// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import Foundation

/// Simple Imaging Polynomial distortion (Shupe et al. 2005), as HST's
/// calibrated frames and many ground-based pipelines write it: `-SIP` on
/// CTYPE plus `A_p_q` / `B_p_q` (and optionally `AP_p_q` / `BP_p_q`).
///
/// Offsets are pixels from the reference pixel (`u = x − CRPIX1`). The
/// forward polynomials are the definition; the inverse is solved against
/// them (Newton), starting from `AP`/`BP` when the header gives them — the
/// same answer astropy's `all_world2pix` gives, not only the approximation
/// `AP`/`BP` encode. Without SIP a WFC3 corner lands several pixels off.
public struct SIPDistortion: Sendable, Equatable {

    /// One term `c · u^p · v^q`.
    public struct Term: Sendable, Equatable {
        public let p: Int
        public let q: Int
        public let coefficient: Double
    }

    public let a: [Term]
    public let b: [Term]
    /// Inverse approximation, when the header has one.
    public let ap: [Term]
    public let bp: [Term]

    public init(a: [Term], b: [Term], ap: [Term] = [], bp: [Term] = []) {
        self.a = a
        self.b = b
        self.ap = ap
        self.bp = bp
    }

    /// Reads SIP from a header whose CTYPE1 ends in `-SIP` and that has
    /// `A_ORDER`/`B_ORDER`; nil otherwise (or when every term is zero).
    public static func from(header: FITSHeader) -> SIPDistortion? {
        let ctype = (header.string("CTYPE1") ?? "").uppercased()
        guard ctype.hasSuffix("-SIP"), header.contains("A_ORDER"), header.contains("B_ORDER") else {
            return nil
        }
        let a = terms("A", order: header.int("A_ORDER"), header)
        let b = terms("B", order: header.int("B_ORDER"), header)
        guard !a.isEmpty || !b.isEmpty else { return nil }
        return SIPDistortion(
            a: a, b: b,
            ap: terms("AP", order: header.int("AP_ORDER"), header),
            bp: terms("BP", order: header.int("BP_ORDER"), header))
    }

    // MARK: - Transform

    /// Distorted offsets → the offsets the linear WCS takes:
    /// `(u + f(u, v), v + g(u, v))`.
    public func correct(u: Double, v: Double) -> (u: Double, v: Double) {
        (u + Self.evaluate(a, u, v), v + Self.evaluate(b, u, v))
    }

    /// Inverse of ``correct(u:v:)``: the pixel offsets that correct to
    /// `(U, V)`, to 1e-9 px.
    public func distortedOffsets(U: Double, V: Double) -> (u: Double, v: Double) {
        var u = U + Self.evaluate(ap, U, V)
        var v = V + Self.evaluate(bp, U, V)
        for _ in 0..<50 {
            let (cu, cv) = correct(u: u, v: v)
            let (ru, rv) = (cu - U, cv - V)
            // Jacobian of (u + f, v + g).
            let j11 = 1 + Self.derivative(a, u, v, alongU: true)
            let j12 = Self.derivative(a, u, v, alongU: false)
            let j21 = Self.derivative(b, u, v, alongU: true)
            let j22 = 1 + Self.derivative(b, u, v, alongU: false)
            let det = j11 * j22 - j12 * j21
            guard abs(det) > 1e-12 else { break }
            let du = (j22 * ru - j12 * rv) / det
            let dv = (j11 * rv - j21 * ru) / det
            u -= du
            v -= dv
            if abs(du) < 1e-10, abs(dv) < 1e-10 { break }
        }
        return (u, v)
    }

    // MARK: - Internals

    private static func terms(_ prefix: String, order: Int, _ header: FITSHeader) -> [Term] {
        guard order > 0 else { return [] }
        var out: [Term] = []
        for p in 0...order {
            for q in 0...(order - p) {
                let key = "\(prefix)_\(p)_\(q)"
                guard header.contains(key) else { continue }
                let c = header.double(key)
                if c != 0 { out.append(Term(p: p, q: q, coefficient: c)) }
            }
        }
        return out
    }

    private static func evaluate(_ terms: [Term], _ u: Double, _ v: Double) -> Double {
        terms.reduce(0) { $0 + $1.coefficient * pow(u, Double($1.p)) * pow(v, Double($1.q)) }
    }

    private static func derivative(_ terms: [Term], _ u: Double, _ v: Double, alongU: Bool) -> Double {
        terms.reduce(0) { sum, t in
            if alongU {
                guard t.p > 0 else { return sum }
                return sum + t.coefficient * Double(t.p) * pow(u, Double(t.p - 1)) * pow(v, Double(t.q))
            }
            guard t.q > 0 else { return sum }
            return sum + t.coefficient * Double(t.q) * pow(u, Double(t.p)) * pow(v, Double(t.q - 1))
        }
    }
}
