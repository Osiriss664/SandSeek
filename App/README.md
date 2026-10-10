# App (parked)

These files are not part of `Package.swift` and are not built yet.

- `Logic/` run, sandbox and report controllers (was `Sources/TUFFApp/Research`)
- `Mac/` the research screen (was `Sources/TUFFApp/Mac/Research`)
- `Tests/` tests for `Logic/` (was `Tests/TUFFApp/Research`)

They still depend on TUFF app modules (`TUFFAppServer`, `TUFFAppCore`,
`TUFFMacPresentation`, `TUFFModelCatalog` and others) that do not exist in
this repository. Only the import of the research core was renamed
(`TUFFResearchCore` is now `SandSeekCore`). The folder is rebuilt in
Abschnitt 3 of the plan.

## Still to rename in Abschnitt 3

The parked code still uses every old name. Revived as it is, it would talk to
the fork's sandbox instead of SandSeek's. Rename each of these, then search the
folder again for `tuff`, `TUFF`, `9000` and `web-research`:

- [ ] Sandbox port `9000` becomes `9100` (`127.0.0.1:9000` in
      `Logic/ResearchSandboxController.swift`, tests and test support)
- [ ] Image and VM name `tuff-web-research` becomes `sandseek-sandbox`
- [ ] Firewall table `inet tuff_sandbox` becomes `inet sandseek_sandbox`
- [ ] Path `Sandbox/web-research` becomes `Sandbox`
- [ ] Repository folder `~/Developer/TUFF` (also in
      `Mac/ResearchWorkspaceView.swift`)
- [ ] Reports folder `Application Support/TUFF/Research Reports`
      (`Logic/ResearchReportStore.swift`); copy the old reports, do not move them
- [ ] Modules `TUFFAppServer`, `TUFFAppCore`, `TUFFAppResearch`,
      `TUFFMacPresentation`, `TUFFMacTheme`, `TUFFModelCatalog` (replace with
      SandSeek types; model display names come from the new `ResearchModelTable`)
- [ ] The `TUFFServer` process name, the `TUFF.app` path and the `TUFF`
      binary that `ResearchServerProcess.swift` and
      `ResearchModelServerController.swift` look for (the model server is
      still TUFF's, so decide first which of these are right as they are)
- [ ] Log folder `Library/Logs/TUFF/research-server.log` and the app support
      folder `TUFF/Research` (`ResearchSandboxController.swift:179`)
- [ ] Citation scheme `tuff-research-source` and the temp log prefix
      `tuff-research-` (`ResearchAnswerFormatter.swift`, `ResearchProcessRunner.swift`)
- [ ] User-visible texts: "TUFF folder", "TUFF checkout", "outside TUFF",
      "Choose TUFF Folder…", "the TUFF server", and `tuff research` in comments
- [ ] Test strings and fixtures in `Tests/ResearchAppTests.swift` (lines near
      252, 562, 576, 586, 609-613, 991) and `Tests/ResearchTestSupport.swift`
      (116-119, 190, plus `TUFFResearchTests` and `TUFFCheckout`)
