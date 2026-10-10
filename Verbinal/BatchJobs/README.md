# Batch jobs

Headless jobs on CANFAR, for an assistant: launching them, reading their state, logs and events.

- **`MCP/HeadlessAgentTools`** launches and lists jobs, with the replica and image checks.
- **`MCP/HeadlessJobReadTools`** reads one job.
  - `get_headless_job` falls back to the job history once CANFAR no longer lists it.
  - A job without a pod is coming or gone: `HeadlessJobPresence`.
- **`JobHistory/` (beside it)** keeps the jobs CANFAR no longer lists, with how each ended. Its records
  sync when the person chooses.
- **On screen.** The Portal's Batch Jobs card and sheet are in `Views/` and `ViewModels/`
  (`HeadlessMonitorModel`).
