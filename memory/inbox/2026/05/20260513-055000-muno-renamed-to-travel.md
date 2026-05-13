# Trip-Planner Repo Renamed to Travel

Kadyapam renamed the trip-planner repository from `noetl/muno` to
`noetl/travel`.

Updates made:

- Local submodule remote changed to `git@github.com:noetl/travel.git`.
- ai-meta submodule path moved from `repos/muno` to `repos/travel`.
- `.gitmodules` now tracks `[submodule "repos/travel"]`.
- `noetl/travel#15` updated package references:
  - OCI source label now points at `https://github.com/noetl/travel`.
  - Default container image repo is now `ghcr.io/noetl/travel`.
- `noetl/docs#68` updated Tutorial 08 commands and repo link from
  `repos/muno` / `noetl/muno` to `repos/travel` / `noetl/travel`.
- The trip-planner scoping issue now records `noetl/travel` as the home-base
  repo and notes the 2026-05-13 rename.

Auth0 note:

Kadyapam said they will update Auth0 for the new naming. The app/domain itself
still uses the existing Muno UI/domain terms until that Auth0/domain naming
decision lands.

