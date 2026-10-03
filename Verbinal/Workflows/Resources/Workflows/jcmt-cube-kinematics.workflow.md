# Spectral-cube kinematics of a molecular cloud (JCMT)
> Explore a JCMT line cube in 3D, probe spectra at the cores, and produce moment maps.
Tags: spectral-cube, JCMT, kinematics, sub-mm
Time: ~2 h

## Steps

- [ ] **Find cube observations of the cloud** — Search collection JCMT at the cloud position for
      cube data products (HARP/ACSIS line cubes).
      Tool: search_observations
      View: search
- [ ] **Check the line and velocity coverage** — Inspect the observation metadata: which
      transition (e.g. CO 3–2), what velocity resolution and range.
      Tool: get_observation_caom2
      View: search
- [ ] **Download the cube** — Pull the chosen cube into the research archive.
      Tool: download_observation
      View: research
- [ ] **Open it in the Cube Viewer** — Volume-render the cube; orbit to see the emission
      structure in position-position-velocity space.
      Tool: open_cube
- [ ] **Scrub the channels** — Use the channel scrubber and its intensity waveform to locate the
      velocity range that carries the emission; tune the transfer function until faint structure
      separates from noise.
      Tool: set_cube_view
- [ ] **Probe spectra at the cores** — Extract spectra at each dense core / peak; note velocity
      centroids and line widths, and look for wings that hint at outflows.
      Tool: probe_cube_spectrum
- [ ] **Build moment maps** — Moment 0 (integrated intensity) and moment 1 (velocity field), with
      masks refined as you go, in Python with run_code on Remote Compute — or in the cube-analysis
      notebook (template: cube), with the Notebook add-on.
      Tool: run_code
      Add-on: create_analysis_notebook
      View: remoteCompute
- [ ] **Export figures** — Export publication figures of the key views and maps.
      Tool: export_cube_figure
- [ ] **Store the products** — Moment maps, spectra tables, and the code go to VOSpace with
      the run parameters recorded.
      Tool: upload_file_to_vospace
      View: storage
