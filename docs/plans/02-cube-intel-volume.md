# Dev plan — Cube Viewer: Intel Mac volume / frame missing

**Status:** Phase B started on `release/1.3.4` (error banner + decoupled wireframe). Phase A still needs Intel Mac logs.  
**Surface:** Cube Viewer volume mode (Metal)  
**Hardware report:** 2019 Intel Mac — SwiftUI chrome OK; **volume figure + cube wireframe missing**  
**Related:** [Global plan](./00-global.md)

## Findings

- Stack: **Metal + MetalKit** (`MTKView` + `Cube.metal` ray-march). Not SceneKit.
- Volume **and** wireframe share one `draw(in:)` guard: missing `pipeline` or any of three textures → **both skip**; axis captions / controls / spectrum stay visible.
- Failures use `try?` / silent early returns — **`isReady` is unused** in UI.
- No `supportsFamily` / `#if arch(arm64)` gates. Half-float path already uses portable `UInt16` bits for x86_64 App Store builds — unlikely to hide the wireframe alone.
- Most likely: Metal device/pipeline/texture init failure on Iris/UHD, or upload never attaching textures.

## Goals

1. Reproduce and log the exact early-return on a 2019 Intel Mac.
2. Surface a user-visible error when volume mode cannot render (not a blank black/clear view).
3. Fix or degrade gracefully (smaller max³, alternate pixel format, or “volume unavailable — use slices”).

## Approach

### Phase A — Instrument & reproduce (P0)

1. On Intel Mac: Console / temporary debug overlay logging:
   - `MTLCreateSystemDefaultDevice()` nil?
   - `makeDefaultLibrary()` / pipeline `try` error
   - `makeTexture` for `.r16Float` 3D nil? size?
   - `volumeData` present? `setVolume` called?
   - `renderer.isReady`
2. Capture GPU name, macOS version, cube dimensions after downsample.
3. Confirm slice mode still works (CPU path) on the same file.

### Phase B — Harden render path (P0/P1)

1. Replace silent `try?` with captured `Error` / reason string on `CubeVolumeRenderer`.
2. Bind UI: banner or empty-state in `CubeVolumeView` when `!isReady` (“Could not create Metal volume renderer: …”).
3. Wireframe: consider drawing overlay even if volume texture failed (decouple frame from volume) so users still see the cube frame.
4. If texture size fails: auto-downsample further (below 512³) and retry once.
5. If `.r16Float` 3D unsupported (rare): probe alternate format or fall back to slice-only with message.

### Phase C — Regression (P1)

1. Unit-test half-float round-trip (already partly covered).
2. Optional: mockable “device factory” for nil-device tests.
3. Manual checklist: Intel 2019 + Apple Silicon smoke.

## Acceptance

- [ ] Intel Mac either shows volume+frame or a clear error / slice fallback — never a silent empty Metal view.
- [ ] Wireframe visible when volume texture fails (if Phase B.3 ships).
- [ ] Logs/reasons available for support (debug or “Copy diagnostics”).

## Key files

- `Verbinal/CubeViewer/Render/CubeVolumeRenderer.swift`
- `Verbinal/CubeViewer/Render/Cube.metal`
- `Verbinal/CubeViewer/Views/CubeVolumeView.swift`
- `Verbinal/CubeViewer/ViewModels/CubeViewerModel.swift`
- `shared/VerbinalKit/.../Cube/HalfFloat.swift`

## Effort

| Phase | Size |
|-------|------|
| A | S (needs Intel machine access) |
| B | M |
| C | S |
