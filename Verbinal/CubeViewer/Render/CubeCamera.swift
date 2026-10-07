// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin

import CoreGraphics
import simd

/// The volume view's camera: an orbit about the cube, drawn as a box
/// scaled to its shape (x and y by the spatial aspect, z by the spectral
/// scale). The renderer draws through it, and the axis captions and marks
/// are placed with it — one camera, so a caption or a mark sits where the
/// volume is drawn.
struct CubeCamera {
    var azimuth: Float
    var elevation: Float
    var distance: Float
    var boxScale: SIMD3<Float>
    /// Width over height of the view.
    var aspect: Float

    static let fieldOfView: Float = 38 * .pi / 180

    /// The box for a cube whose (possibly binned) plane is `nx`×`ny`.
    static func boxScale(nx: Int, ny: Int, spectralScale: Float) -> SIMD3<Float> {
        let m = Float(max(nx, ny))
        guard m > 0 else { return SIMD3(1, 1, spectralScale) }
        return SIMD3(Float(nx) / m, Float(ny) / m, spectralScale)
    }

    /// Where voxel centre (x, y, channel) of an `nx`×`ny`×`nz` cube is in the
    /// unit box (−½…½ on each axis; y up, as FITS rows go).
    static func boxPoint(voxelX x: Double, _ y: Double, _ z: Double, nx: Int, ny: Int, nz: Int) -> SIMD3<Float> {
        SIMD3(Float((x + 0.5) / Double(nx) - 0.5), Float((y + 0.5) / Double(ny) - 0.5), Float((z + 0.5) / Double(nz) - 0.5))
    }

    var position: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        return SIMD3(distance * ce * sin(azimuth), distance * se, distance * ce * cos(azimuth))
    }

    /// The box's model matrix and the view-projection.
    var matrices: (model: simd_float4x4, viewProj: simd_float4x4) {
        let model = simd_float4x4(diagonal: SIMD4(boxScale.x, boxScale.y, boxScale.z, 1))
        let view = makeLookAt(eye: position, center: .zero, up: SIMD3(0, 1, 0))
        let proj = makePerspective(fovyRadians: Self.fieldOfView, aspect: aspect, near: 0.01, far: 50)
        return (model, proj * view)
    }

    /// A point of the unit box on a view of `size`, in points with y down;
    /// nil behind the camera.
    func screen(ofBoxPoint point: SIMD3<Float>, in size: CGSize) -> CGPoint? {
        let (model, viewProj) = matrices
        let modelViewProj = viewProj * model
        let clip = modelViewProj * SIMD4(point, 1)
        guard clip.w > 0.0001 else { return nil }
        let x = clip.x / clip.w, y = clip.y / clip.w
        return CGPoint(x: CGFloat(x * 0.5 + 0.5) * size.width, y: CGFloat(1 - (y * 0.5 + 0.5)) * size.height)
    }
}

// MARK: - Matrix helpers (column-major, Metal NDC z ∈ [0,1])

func makePerspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / max(aspect, 0.0001)
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(xs, 0, 0, 0),
        SIMD4(0, ys, 0, 0),
        SIMD4(0, 0, zs, -1),
        SIMD4(0, 0, zs * near, 0)
    ))
}

func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return simd_float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}
