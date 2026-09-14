# Navigator organisation boundary

User requirement: dragging, dropping, grouping, pinning, sorting, and assigning items in Navigator must only change Navigator's own local metadata. Never alter Codex's project assignments, saved folder structure, or source files, and never move or rename filesystem directories as a side effect of these interactions. Do not introduce upstream synchronisation for organisation gestures. Keep this boundary covered by regression tests.

Explicit **New Project** creation is an exception: register the chosen folder with Codex through its project API and use the returned project ID for new sessions. This does not authorize upstream changes from dragging, grouping, pinning, sorting, or assigning existing items. Never edit Codex’s saved state files directly.
