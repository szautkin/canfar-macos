# Marks

The person's annotations on an image or a cube: circles, boxes, callouts, text. They are image data,
kept with the file; they are not the screen hints in `UIPointer/`.

- **`MarkStore`.**
  - It keeps each file's marks (each extension's, for FITS) under the file's identity (`FileOrigins`).
  - Marks kept under a path before are still read, and move on their first change.
- **`MarkEditor`, `MarkGeometry` and `MarkOverlay`** edit and draw marks for both viewers.
- **`Sync/`.** The marks of files every device knows, one set per file, when the person chooses.
