# Contributing to Folio

`docs/TEAM_OWNERSHIP.md` is authoritative. Preserve assignments and each contributor's commits.

## Start work

Commit or stash your own local changes before switching branches. Never discard someone else's changes.

```sh
git fetch origin
git switch feature/YOUR-ASSIGNED-BRANCH
git pull --ff-only origin feature/YOUR-ASSIGNED-BRANCH
git merge origin/develop
open Folio/Folio.xcodeproj
```

If the feature branch exists only remotely, use `git switch --track origin/feature/YOUR-ASSIGNED-BRANCH` instead.
Resolve conflicts with the affected owner. Never force-push or reset shared branches.

## Submit

Use Conventional Commits, for example `feat(scanner): add receipt capture` or `fix(storage): handle corrupt records`.
Push your feature branch and open a PR targeting `develop`. Request review from another team member, especially for shared contracts. Run the README build and unit-test commands first and include their actual results. Merge commits preserve genuine contribution history. Only tested release PRs go from `develop` to `main`; never commit directly to `main`.

Keep views declarative. View models invoke use cases, use cases depend on domain protocols, and adapters own Apple framework details. Keep new files within your feature folder. Discuss changes to Domain, Data, App and Core in the PR before merging.

Use semantic colours, scalable system text styles, accessibility labels for icon-only controls and layouts that support Dynamic Type. Test light/dark appearance and VoiceOver on feature screens. Do not log receipt text, amounts or images. Test failures and unavailable hardware/permissions as well as success paths.

Xcode discovers source files through synchronized folders. Do not add explicit build entries for those files. Do not commit `.DS_Store`, user settings, signing secrets, DerivedData or result bundles. Use mock/in-memory repositories in tests.
