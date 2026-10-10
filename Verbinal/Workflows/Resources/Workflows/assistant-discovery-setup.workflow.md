# Set up the assistant for discovery work
> Give the assistant two standing guides — claims with their evidence, and the work kept in CANFAR — before a search for new objects.
Tags: assistant, AI Guide, discovery, reproducibility
Time: ~10 min

## Steps

- [ ] **Read what is there** — The session's instructions, and the guides the person already
      keeps; nothing here replaces them.
      Tool: describe_app, list_guide_tools
      View: aiGuide
- [ ] **Propose the guide on claims and evidence** — add_guide_tool, name `claims_and_evidence`,
      description "How to report findings: candidates, evidence, dates, what was not checked.",
      body: "Call what you find a candidate, not a confirmation, until follow-up decides. Give
      each claim its evidence (the data, the code, the run) and its date. Say what you did not
      check. Count every stage of a selection, from the first query to the last cut, and keep the
      rejected ones with their reason. Write a prediction before the data that will test it."
      Tool: add_guide_tool
      View: aiGuide
      Note: The person approves it in Pending; it then applies to every assistant on this Mac.
- [ ] **Propose the guide on keeping the work in CANFAR** — add_guide_tool, name
      `keep_work_in_canfar`, description "Where data and results go: CANFAR storage and compute,
      not the Mac.", body: "Keep data and results in the person's VOSpace, in a folder named for
      the project. Run processing on CANFAR (run_code, batch jobs) next to the data, at the
      smallest shape that runs, and write outputs to storage so a run can resume. Download to the
      Mac only to look at something, and say so."
      Tool: add_guide_tool
      View: aiGuide
- [ ] **Confirm they are there** — Once approved, the guides are listed, and describe_app opens
      with them as standing rules.
      Tool: list_guide_tools, describe_app
      View: aiGuide
