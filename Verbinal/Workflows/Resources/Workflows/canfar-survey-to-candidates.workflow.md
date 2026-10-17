# A survey on CANFAR: from a query to candidates
> Select data with ADQL, process every target in batch jobs next to the data, and keep the candidates with the evidence for each.
Tags: CANFAR, survey, batch, candidates, reproducibility
Time: ~1 day (mostly waiting)

## Steps

- [ ] **Write down the stages first** — Before touching data, write what makes a candidate and
      the cuts, in order; each stage will get a count. Keep it with the work.
      Tool: upload_text_to_vospace
      View: storage
      Note: A claim is only as good as the stages it passed; count them all, rejects included.
- [ ] **Select the data with ADQL** — Read the archive's tables, write the query, check it, run it.
      Tool: describe_tap_schema, validate_adql_query, execute_adql_query
      View: search
- [ ] **Save the query** — The selection is a result in itself; keep it reproducible.
      Tool: save_query
      View: search
- [ ] **Keep the selection in storage** — Export the results and put the file in the project's
      folder in VOSpace: the target list the jobs will read.
      Tool: export_search_results, upload_file_to_vospace, list_vospace_path
      View: storage
- [ ] **Pick the image** — An image that already carries the software, rather than installing it
      in every job.
      Tool: find_images_with_packages
      View: portal
- [ ] **Write the processing so it resumes** — One script: it reads the target list from /arc,
      takes every REPLICA_COUNT-th target starting at REPLICA_ID, writes one output per target
      (or an error file), and skips targets already done. Try it on three targets with run_code.
      Tool: upload_text_to_vospace, run_code, run_code_output
      View: remoteCompute
      Note: Skipping what is done makes a failed or stopped run cheap to start again.
- [ ] **Validate the method first** — Run it on targets whose answer is known, and on data where
      there is nothing to find (a null test). Keep both outputs in storage.
      Tool: run_code, run_code_output
      View: remoteCompute
      Note: A method that finds what is known, and nothing where there is nothing, earns its candidates.
- [ ] **Run it in shards** — Launch the script as one batch job with replicas, at the smallest
      shape that runs; to resume, launch it again.
      Tool: launch_headless_job
      View: portal
      Note: GPUs only if the script uses them: read get_platform_load's gpu (free, perSession), and ask for a count the platform offers.
- [ ] **Watch the jobs** — States, logs and events; a replica that fails is investigated, not
      skipped.
      Tool: list_headless_jobs, get_headless_job_logs, get_headless_job_events, list_job_history
      View: portal
- [ ] **Count what came out** — Every target has an output or an error; read the tables and look
      at the plots the jobs wrote.
      Tool: list_vospace_path, read_vospace_file
      View: storage
- [ ] **Keep each surviving object in Research** — Save the observation behind it, and tag each
      with the stage it reached; a rejected one keeps its reason as a tag or in its note.
      Tool: save_observation_to_research, bulk_update_observation_notes
      View: research
- [ ] **Check the survivors against the archive** — The resolver's object type, and CADC's other
      observations of the position. Write in the note what was checked, when, and what was not.
      Tool: resolve_target, search_observations, update_observation_note
      View: research
      Note: Candidates, not confirmations: say what follow-up would decide.
- [ ] **Write the funnel** — The count at every stage, from the targets selected to the
      candidates kept, as a file beside the outputs.
      Tool: list_downloaded_observations, upload_text_to_vospace
      View: storage
- [ ] **Share it** — Export the Research bundle to storage, and let the group read the project's
      folder (the person approves sharing).
      Tool: export_research_bundle, set_vospace_acl
      View: storage
