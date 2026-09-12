# TestItemControllers

[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://julia-testitems.org/TestItemControllers.jl/)
[![Build Status](https://github.com/julia-testitems/TestItemControllers.jl/actions/workflows/juliaci.yml/badge.svg?branch=main)](https://github.com/julia-testitems/TestItemControllers.jl/actions/workflows/juliaci.yml)
[![codecov](https://codecov.io/gh/julia-testitems/TestItemControllers.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/julia-testitems/TestItemControllers.jl)

This packages implements all the functionality to run test items. It is used internally by the VS Code extension.

## Working on this package

Note that the content of the `packages` and `packages-old` folder should never be manually edited. All subfolders there are
git subtrees and one should only use the provided Julia script to update them from upstream.

## Repository scripts

| Script | Purpose |
|:-------|:--------|
| `scripts/update_vendored_packages.jl` | Reconcile the vendored `packages/` trees with `scripts/vendored_packages.jl`. |
| `scripts/install_julia_versions.jl` | Install every supported Julia via juliaup. |
| `scripts/update_app_environments.jl` | Regenerate the per-version test process environments. |

`scripts/vendored_packages.jl` is the list the first of those works from: add a package
there and run it with `--apply` to vendor it. Nothing records which version is vendored —
that is read back from each tree's own `Project.toml`, and `--verify` audits it against the
commit `git subtree` recorded.
