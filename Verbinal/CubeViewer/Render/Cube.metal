// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (C) 2025-2026 Serhii Zautkin
//
// Volume mode — front-to-back ray-marching of the half-float 3D texture with
// early ray termination, jittered starts (kills banding), composite and MIP
// modes, and an opacity transfer-function texture. Ported from the v-cube web
// viewer's GLSL (src/render/volumeView.ts). Uses a fullscreen-triangle pass:
// the ray is reconstructed from the inverse view-projection, so there is exactly
// one fragment per pixel (no cube geometry, no face-culling subtleties).

#include <metal_stdlib>
using namespace metal;

struct CubeUniforms {
    float4x4 invViewProj;
    float4x4 inverseModel;
    float2 window;     // normalized lo, hi
    float steps;
    float density;
    float jitter;
    int stretch;
    int mip;
    float pad0;
};

struct VertexOut {
    float4 position [[position]];
    float2 ndc;
};

// Fullscreen triangle from the vertex id — no vertex buffer needed.
vertex VertexOut vertex_cube(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2); // (0,0),(2,0),(0,2)
    float2 ndc = uv * 2.0 - 1.0;
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.ndc = ndc;
    return out;
}

// Stretch index order matches FITSRenderParams.StretchMode.allCases so slice and
// volume apply the identical stretch.
static inline float applyStretch(float x, int mode) {
    x = clamp(x, 0.0, 1.0);
    switch (mode) {
        case 1: return log10(1.0 + 9.0 * x);            // log
        case 2: return sqrt(x);                          // sqrt
        case 3: return x * x;                            // squared
        case 4: return asinh(10.0 * x) / asinh(10.0);    // asinh
        default: return x;                               // linear
    }
}

static inline float2 hitBox(float3 orig, float3 dir) {
    float3 invDir = 1.0 / dir;
    float3 t0 = (float3(-0.5) - orig) * invDir;
    float3 t1 = (float3(0.5) - orig) * invDir;
    float3 tmin = min(t0, t1);
    float3 tmax = max(t0, t1);
    return float2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
}

static inline float hashf(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

fragment float4 fragment_cube(VertexOut in [[stage_in]],
                              constant CubeUniforms &u [[buffer(0)]],
                              texture3d<float> dataTex [[texture(0)]],
                              texture2d<float> cmapTex [[texture(1)]],
                              texture2d<float> tfTex   [[texture(2)]]) {
    constexpr sampler samp(filter::linear, address::clamp_to_edge);

    // Reconstruct the world-space ray from screen NDC, then map into unit-box
    // (texture) space via the inverse model matrix (model = spatial/spectral scale).
    float4 nearH = u.invViewProj * float4(in.ndc, 0.0, 1.0);
    float4 farH  = u.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 nearW = nearH.xyz / nearH.w;
    float3 farW  = farH.xyz / farH.w;
    float3 ro = (u.inverseModel * float4(nearW, 1.0)).xyz;
    float3 rd = normalize((u.inverseModel * float4(farW - nearW, 0.0)).xyz);

    float2 bounds = hitBox(ro, rd);
    bounds.x = max(bounds.x, 0.0);
    if (bounds.x >= bounds.y) { discard_fragment(); return float4(0.0); }

    float dt = 1.7320508 / u.steps; // unit-cube diagonal / steps
    float t = bounds.x + dt * hashf(in.position.xy + u.jitter);

    float3 acc = float3(0.0);
    float alpha = 0.0;
    float mip = 0.0;

    for (int i = 0; i < 2048; i++) {
        if (t > bounds.y || alpha > 0.98) break;
        if (float(i) >= u.steps * 1.7320508) break;
        float3 p = ro + rd * t + 0.5;
        float r = dataTex.sample(samp, p).r;
        if (r > 0.0) {
            float v = (r - u.window.x) / max(u.window.y - u.window.x, 1.0e-6);
            float s = applyStretch(v, u.stretch);
            if (u.mip == 1) {
                mip = max(mip, s);
            } else {
                float a = clamp(tfTex.sample(samp, float2(s, 0.5)).r * u.density * dt * 60.0, 0.0, 1.0);
                float3 c = cmapTex.sample(samp, float2(s, 0.5)).rgb;
                acc += (1.0 - alpha) * a * c;
                alpha += (1.0 - alpha) * a;
            }
        }
        t += dt;
    }

    if (u.mip == 1) {
        if (mip <= 0.003) { discard_fragment(); return float4(0.0); }
        float a = smoothstep(0.0, 0.25, mip);
        return float4(cmapTex.sample(samp, float2(mip, 0.5)).rgb * a, a); // premultiplied
    }
    if (alpha <= 0.003) { discard_fragment(); return float4(0.0); }
    return float4(acc, alpha); // premultiplied
}
