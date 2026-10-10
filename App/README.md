# App (parked)

These files are not part of `Package.swift` and are not built yet.

- `Logic/` run, sandbox and report controllers (was `Sources/TUFFApp/Research`)
- `Mac/` the research screen (was `Sources/TUFFApp/Mac/Research`)
- `Tests/` tests for `Logic/` (was `Tests/TUFFApp/Research`)

They still depend on TUFF app modules (`TUFFAppServer`, `TUFFAppCore`,
`TUFFMacPresentation`, `TUFFModelCatalog` and others) that do not exist in
this repository. Only the import of the research core was renamed
(`TUFFResearchCore` is now `SandSeekCore`). The folder is rebuilt in plan
section 3.
