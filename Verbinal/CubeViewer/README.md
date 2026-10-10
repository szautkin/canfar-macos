# Cube Viewer

3D spectral cubes: slices, the volume (Metal), spectra under a pixel. macOS only.

- **`CubeViewerModel`.** One tab, held by `CubeTabHostModel`. `Render/` draws the volume.
- **Marks** on a cube live on a channel (`CubeMarks`), kept by `Marks/`.
- **`MCP/`.** The cube tools, and the cube forms of the viewers' shared tools (`open_cube`,
  `get_cube_image`).
