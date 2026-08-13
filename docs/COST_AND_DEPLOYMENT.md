# Cost and deployment

## Near-zero fixed-cost target

- GitHub + Codex Cloud for implementation
- Free-tier web hosting during preview where practical
- Supabase free tier for early auth/database/private-storage use where practical
- Deterministic mocks for normal development and CI
- No always-on GPU

## Variable cost

Real voice/avatar inference requires compute. The intended design uses an on-demand worker that can scale to zero. Before real inference is enabled, the UI must show an estimated per-job cost and the system must enforce per-job and monthly budget caps.

## Laptop impact

The normal development, CI, database, and render workflow is cloud-first. A developer laptop should only need a browser for routine operation.

## Cost gates

- No paid provider resource is created merely because an adapter exists.
- Prove the governed workflow with mocks before GPU spend.
- Measure actual rendering duration/cost before production approval.
- Expire superseded previews and avoid retaining duplicate media indefinitely.
