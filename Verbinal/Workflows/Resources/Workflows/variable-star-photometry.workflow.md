# Variable-star time-series photometry (CFHT / NEOSSat)
> Find multi-epoch imaging of a field, build light curves, and search for variability.
Tags: photometry, variability, time-series, CFHT, NEOSSat
Time: ~3 h

## Steps

- [ ] **Resolve the field** — Cluster or field centre coordinates; note the field of view you
      need to cover.
      Tool: resolve_target
      View: search
- [ ] **Query multi-epoch imaging in one filter** — Search CFHT MegaCam (or NEOSSat for bright
      targets) at the field position; a single consistent filter keeps the photometry differential.
      Tool: search_observations
      View: search
- [ ] **Assess the cadence** — Sort epochs by date: how many epochs, over what baseline, with
      what gaps? Decide whether the sampling supports your expected periods.
      View: search
      Note: Aliasing: nightly cadence hides periods near 1 day and its harmonics.
- [ ] **Save the query** — The epoch selection is a result in itself; keep it reproducible.
      Tool: save_query
- [ ] **Bulk-download the series** — Pull every usable epoch into the research archive in one go.
      Tool: download_observations_bulk
      View: research
- [ ] **Write the photometry code** — Aperture photometry of the first downloaded observation
      in Python (astropy, photutils) with run_code on Remote Compute, then generalize it over all
      epochs. With the Notebook add-on, seed a notebook instead (template: photometry).
      Tool: run_code
      Add-on: create_analysis_notebook
      View: remoteCompute
- [ ] **Measure per-epoch photometry** — Aperture photometry of the target and 5–10 comparison
      stars in every epoch; build differential magnitudes against the comparison ensemble.
      Tool: run_code
      Add-on: run_all_cells
      View: remoteCompute
- [ ] **Search for variability** — Plot light curves; compute scatter vs magnitude to find
      outliers; run a Lomb–Scargle periodogram on candidates.
      Tool: run_code
      View: remoteCompute
- [ ] **Publish the products** — Save light-curve tables and the code to VOSpace so the
      analysis travels with the data.
      Tool: upload_file_to_vospace, create_vospace_folder
      View: storage
- [ ] **Log candidates** — One note per candidate variable: period, amplitude, classification
      guess, follow-up needed.
      Tool: update_observation_note, bulk_update_observation_notes
      View: research
