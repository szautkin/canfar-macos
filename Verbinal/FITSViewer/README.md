# FITS Viewer

2D images and tables from FITS files, in tabs.

- **`FITSViewerModel`.** One tab's file and view. It is split by job: the crosshair, the geometry on
  screen, and the coordinates between screen, pixel and sky. `FITSTabHostModel` holds the tabs.
- **`BookmarkStore`.** Sky bookmarks, kept under the file's identity (`FileOrigins`), so they follow a
  file of Research or of storage.
- **Figures.** They are written through `FigureFile`, which tells `ResultDestination`.
- **`MCP/`.** The FITS tools. `ViewerImageTool` and `OpenDownloadedObservationTool` serve both viewers;
  their cube forms are in `CubeViewer/MCP`.
