# Plan: Multi-Environment Test Runs in TestItemControllers

## Context

Currently, `execute_testrun` accepts exactly one `TestProfile` and runs all test items against that single Julia environment. This limits the GitHub Actions workflow (`testitem-workflow`) to launching one job per (Julia version × platform) combination, which can produce 60+ parallel jobs for packages supporting many Julia versions across all platforms. GitHub's concurrency limits mean most of these jobs sit queued, wasting time on repeated per-job setup overhead.

The goal is to refactor the `execute_testrun` API so that a single test run can specify multiple test environments (e.g., different Julia versions), with a list of (test item, environment) work units. This enables a future workflow where one GitHub job per platform runs all Julia versions sequentially or with a scheduler.

**Phase 1 (this plan):** Change the public API and internal data structures. Keep a runtime guard that only one test environment per run is allowed. Defer the multi-env scheduler to a later phase.

**Phase 2 (future):** Remove the single-env guard and implement a process scheduler that dynamically allocates, reclaims, and launches processes across environments within a global `max_processes` budget.

---

## New and Changed Types

### New: `TestEnvironment` (replaces `TestProfile` as the public API type)

**File: `src/datatypes.jl`**

```julia
struct TestEnvironment
    id::String
    julia_cmd::String
    julia_args::Vector{String}
    julia_num_threads::Union{Missing,String}
    julia_env::Dict{String,Union{String,Nothing}}
    mode::String   # "Normal", "Coverage", or "Debug"
end
```

This is what callers pass in. Each `TestEnvironment` represents a distinct Julia process configuration (different Julia version, different env vars, different coverage mode, etc.). The `id` field is used to reference this environment from work units and callbacks.

### New: `TestRunItem` (the work unit type)

**File: `src/datatypes.jl`**

```julia
struct TestRunItem
    testitem_id::String
    test_env_id::String
    timeout::Union{Nothing,Float64}
    log_level::Symbol
end
```

Each `TestRunItem` represents a single unit of work: "run test item X in environment Y with these settings." The `test_env_id` references a `TestEnvironment.id`. Future fields like `max_retries` can be added later.

### Rename: current `TestEnvironment` → `ProcessEnv`

**File: `src/testenvironment.jl`**

The current `TestEnvironment` struct (which combines Julia config with package info from the test item) becomes `ProcessEnv`. This is the internal process pool key — it uniquely identifies what kind of process is needed.

```julia
struct ProcessEnv
    project_uri::Union{Nothing,String}
    package_uri::String
    package_name::String
    julia_cmd::String
    julia_args::Vector{String}
    julia_num_threads::Union{Missing,String}
    mode::String
    env::Dict{String,Union{String,Nothing}}
end
```

Keep the existing `hash`, `==`, and `isequal` implementations, just rename the type. Update all references throughout the codebase:
- `src/testitemcontroller.jl` — `_item_env` return type, `process_pool` type parameter, all local variables
- `src/state.jl` — `TestProcessState.env` field type, `TestRunState.procs` type parameter
- `src/messages.jl` — all message types that reference `TestEnvironment`
- Anywhere else `TestEnvironment` appears as a type

### Remove: `TestProfile`

**File: `src/datatypes.jl`**

Delete the `TestProfile` struct entirely. Its fields are distributed as follows:
- `id`, `julia_cmd`, `julia_args`, `julia_num_threads`, `julia_env`, `mode` → `TestEnvironment`
- `max_process_count` → separate parameter on `execute_testrun`
- `coverage_root_uris` → separate keyword parameter on `execute_testrun`
- `log_level` → per-work-unit in `TestRunItem`
- `label` → dropped (was only for display; `TestEnvironment.id` serves this purpose)

---

## Changed: `execute_testrun`

**File: `src/testitemcontroller.jl` (around line 1771)**

New signature:

```julia
function execute_testrun(
    controller::TestItemController,
    testrun_id::String,
    test_environments::Vector{TestEnvironment},
    test_items::Vector{TestItemDetail},
    work_units::Vector{TestRunItem},
    test_setups::Vector{TestSetupDetail},
    max_processes::Int;
    coverage_root_uris::Union{Nothing,Vector{String}} = nothing,
    token = nothing
)
```

### Implementation changes inside `execute_testrun`:

1. **Runtime guard (Phase 1):**
   ```julia
   unique_env_ids = unique(wu.test_env_id for wu in work_units)
   @assert length(unique_env_ids) == 1 "Multiple test environments per run not yet supported"
   ```

2. **Build an env lookup:**
   ```julia
   env_by_id = Dict(e.id => e for e in test_environments)
   ```

3. **`_item_env` changes:** Currently uses `tr.profiles[1]` to combine with item package info. Now it takes a `TestEnvironment` (looked up via the work unit's `test_env_id`) and a `TestItemDetail`:
   ```julia
   function _item_process_env(item::TestItemDetail, env::TestEnvironment)
       return ProcessEnv(
           item.project_uri,
           item.package_uri,
           item.package_name,
           env.julia_cmd,
           env.julia_args,
           env.julia_num_threads,
           env.mode,
           env.julia_env
       )
   end
   ```

4. **`remaining_items` → `remaining_work`:** Change the tracking dict from `Dict{String, TestItemDetail}` (keyed by testitem_id) to `Dict{Tuple{String,String}, TestRunItem}` keyed by `(testitem_id, test_env_id)`. Even with the single-env guard, use this key type now to avoid a second refactor later.

5. **`proc_count_by_env` calculation:** Currently computes shares from `profiles[1].max_process_count`. Change to use the `max_processes` parameter. The `max(1, ...)` logic stays the same for Phase 1 (single env).

6. **`coverage_root_uris`:** Pass through to `GetProcsForTestRunMsg` (replacing the previous `profiles[1].coverage_root_uris`).

7. **`log_level`:** For Phase 1 (single env), take from the first work unit: `work_units[1].log_level`. Pass through to `GetProcsForTestRunMsg` as before.

---

## Changed: `TestRunState`

**File: `src/state.jl`**

```julia
mutable struct TestRunState
    id::String
    fsm::FSM{TestRunPhase}
    test_environments::Vector{TestEnvironment}           # NEW
    env_by_id::Dict{String,TestEnvironment}              # NEW: lookup by id
    remaining_work::Dict{Tuple{String,String},TestRunItem}  # CHANGED: (testitem_id, test_env_id) → work unit
    test_items::Dict{String,TestItemDetail}              # NEW: lookup by testitem_id (needed to get package info)
    test_setups::Vector{TestSetupDetail}
    max_processes::Int                                   # NEW
    coverage_root_uris::Union{Nothing,Vector{String}}    # NEW (moved from being per-profile)
    procs::Union{Nothing,Dict{ProcessEnv,Vector{String}}}  # RENAMED type
    testitem_ids_by_proc::Dict{String,Vector{String}}
    stolen_ids_by_proc::Dict{String,Vector{String}}
    items_dispatched_to_procs::Set{String}
    processes_ready_before_acquired::Set{String}
    coverage::Vector{CoverageTools.FileCoverage}
    cancellation_source::CancellationTokens.CancellationTokenSource
    completion_channel::Channel{Any}
end
```

Remove `profiles::Vector{TestProfile}` entirely.

Update the constructor to accept and store the new fields. Initialize `remaining_work` from the work units vector, and `test_items` as a lookup dict.

Also add a helper to resolve which `TestEnvironment` a process belongs to. Given a `ProcessEnv`, find the matching `TestEnvironment` by comparing julia_cmd/args/env/mode fields:

```julia
function _resolve_test_env_id(tr::TestRunState, penv::ProcessEnv)::String
    for env in tr.test_environments
        if env.julia_cmd == penv.juliaCmd &&
           env.julia_args == penv.juliaArgs &&
           isequal(env.julia_num_threads, penv.juliaNumThreads) &&
           env.mode == penv.mode &&
           env.julia_env == penv.env
            return env.id
        end
    end
    error("No matching TestEnvironment for ProcessEnv")
end
```

(Or store a reverse mapping `Dict{ProcessEnv, String}` for efficiency.)

---

## Changed: Reactor Message Handlers

**File: `src/testitemcontroller.jl`**

### Item completion handlers (`TestItemPassedMsg`, `TestItemFailedMsg`, `TestItemErroredMsg`)

Currently these do:
```julia
delete!(tr.remaining_items, msg.testitem_id)
```

Change to resolve the test_env_id from the process, then delete the work unit:
```julia
ps = c.test_processes[msg.testprocess_id]
test_env_id = _resolve_test_env_id(tr, ps.env)
delete!(tr.remaining_work, (msg.testitem_id, test_env_id))
```

Also change the `haskey` guards from `haskey(tr.remaining_items, msg.testitem_id)` to `haskey(tr.remaining_work, (msg.testitem_id, test_env_id))`.

### Callback invocations

Add `test_env_id` as the third argument to all testitem callbacks:

```julia
# Was:
c.callbacks.on_testitem_passed(msg.testrun_id, msg.testitem_id, msg.duration)
# Now:
c.callbacks.on_testitem_passed(msg.testrun_id, msg.testitem_id, test_env_id, msg.duration)
```

Same pattern for `on_testitem_started`, `on_testitem_failed`, `on_testitem_errored`, `on_testitem_skipped`.

### `_check_testrun_complete!`

Change from `isempty(tr.remaining_items)` to `isempty(tr.remaining_work)`.

### `_check_stealing!`

Work stealing is already scoped to the same env (same `ProcessEnv`). No logic change needed — just update type references from `TestEnvironment` to `ProcessEnv`.

### `_get_unchunked_items`

Currently filters `tr.remaining_items` by env. Change to filter `tr.remaining_work`:
```julia
function _get_unchunked_items(tr::TestRunState, penv::ProcessEnv)
    assigned = Set{String}()
    for (_, ids) in tr.testitem_ids_by_proc
        union!(assigned, ids)
    end
    # Find testitem_ids from remaining_work that match this ProcessEnv
    items = [key[1] for (key, wu) in tr.remaining_work
             if _item_process_env(tr.test_items[key[1]], tr.env_by_id[key[2]]) == penv
             && key[1] ∉ assigned]
    return items
end
```

### Timeout handling in `TestItemStartedMsg`

Currently reads timeout from `tr.remaining_items[msg.testitem_id].timeout`. Change to look up the work unit:
```julia
test_env_id = _resolve_test_env_id(tr, ps.env)
wu_key = (msg.testitem_id, test_env_id)
if haskey(tr.remaining_work, wu_key)
    wu = tr.remaining_work[wu_key]
    if wu.timeout !== nothing
        # ... start timeout
    end
end
```

Note: `timeout` moves from `TestItemDetail` to `TestRunItem`. Remove the `timeout` field from `TestItemDetail` (in `src/datatypes.jl`). The `TestItemDetail` struct should only contain static information about the test item definition (code, location, package, etc.), not per-run settings.

### `GetProcsForTestRunMsg` handler and `ProcsAcquiredMsg` handler

Update type references from `TestEnvironment` to `ProcessEnv`. No logic changes for Phase 1.

### `TestRunCancelledMsg` handler

Change the skipped callback to include test_env_id:
```julia
for ((testitem_id, test_env_id), _) in tr.remaining_work
    c.callbacks.on_testitem_skipped(msg.testrun_id, testitem_id, test_env_id)
end
```

### Process replacement in `TestProcessTerminatedInRunMsg`

Currently accesses `tr.profiles[1]` to get coverage_root_uris and log_level for the replacement process. Change to use `tr.coverage_root_uris` and look up the log_level from the work units for the relevant env.

---

## Changed: `GetProcsForTestRunMsg`

**File: `src/messages.jl`**

Update type from `Dict{TestEnvironment,...}` to `Dict{ProcessEnv,...}`:

```julia
struct GetProcsForTestRunMsg <: ReactorMessage
    testrun_id::String
    proc_count_by_env::Dict{ProcessEnv,Int}
    env_content_hash_by_env::Dict{ProcessEnv,Union{Nothing,String}}
    test_setups::Vector{TestItemServerProtocol.TestsetupDetails}
    coverage_root_uris::Union{Nothing,Vector{String}}
    log_level::Symbol
end
```

Also update `ProcsAcquiredMsg`, `ReturnToPoolMsg`, and `PrecompileDoneMsg` — anywhere `TestEnvironment` appears as a type, change to `ProcessEnv`.

---

## Changed: `ControllerCallbacks`

**File: `src/callbacks.jl`**

Add `test_env_id::String` as the third parameter to all testitem callbacks:

```julia
struct ControllerCallbacks{F1,F2,F3,F4,F5,F6,F7,F8,F9,F10,F11}
    on_testitem_started::F1     # (testrun_id, testitem_id, test_env_id) -> nothing
    on_testitem_passed::F2      # (testrun_id, testitem_id, test_env_id, duration) -> nothing
    on_testitem_failed::F3      # (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing
    on_testitem_errored::F4     # (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing
    on_testitem_skipped::F5     # (testrun_id, testitem_id, test_env_id) -> nothing
    on_append_output::F6        # (testrun_id, testitem_id, output) -> nothing
    on_attach_debugger::F7      # (testrun_id, debug_pipe_name) -> nothing
    on_process_created::F8      # (id, package_name, package_uri, project_uri, coverage, env) -> nothing
    on_process_terminated::F9   # (id) -> nothing
    on_process_status_changed::F10  # (id, status) -> nothing
    on_process_output::F11      # (id, output) -> nothing
end
```

---

## Changed: `TestItemController`

**File: `src/testitemcontroller.jl` (top of file)**

Update the `process_pool` type from `Dict{TestEnvironment,Vector{String}}` to `Dict{ProcessEnv,Vector{String}}`.

Update `precompiled_envs` from `Set{TestEnvironment}` to `Set{ProcessEnv}`.

---

## Changed: JSONRPC Adapter (backwards-compatible)

**File: `src/jsonrpctestitemcontroller.jl`**

The JSONRPC protocol types in `src/json_protocol.jl` stay **unchanged** — no new fields, no removed fields. The adapter layer in `jsonrpctestitemcontroller.jl` translates between the old protocol and the new internal API.

### `create_testrun_request`

Convert the single `TestProfile` from the JSONRPC params into the new API:

```julia
function create_testrun_request(params::TestItemControllerProtocol.CreateTestRunParams, jr_controller, token)
    @assert length(params.testProfiles) == 1 "JSONRPC interface currently supports one profile"
    profile = params.testProfiles[1]

    # Convert TestProfile → TestEnvironment
    env = TestEnvironment(
        profile.id,
        profile.juliaCmd,
        profile.juliaArgs,
        coalesce(profile.juliaNumThreads, missing),
        profile.juliaEnv,
        profile.mode
    )

    # Convert TestItemDetail protocol type → internal type
    test_items = [
        TestItemDetail(
            i.id, i.uri, i.label,
            coalesce(i.packageName, nothing),
            coalesce(i.packageUri, nothing),
            coalesce(i.projectUri, nothing),
            coalesce(i.envContentHash, nothing),
            i.useDefaultUsings,
            i.testSetups,
            i.line, i.column, i.code,
            i.codeLine, i.codeColumn
            # NOTE: timeout removed from TestItemDetail, now in TestRunItem
        ) for i in params.testItems
    ]

    # Build TestRunItems: every test item × the single env
    work_units = [
        TestRunItem(
            i.id,
            env.id,
            coalesce(i.timeout, nothing),   # timeout from protocol's TestItemDetail
            jr_controller.controller.log_level
        ) for i in params.testItems
    ]

    # Convert test setups
    test_setups = [
        TestSetupDetail(i.packageUri, i.name, i.kind, i.uri, i.line, i.column, i.code)
        for i in params.testSetups
    ]

    ret = execute_testrun(
        jr_controller.controller,
        params.testRunId,
        [env],
        test_items,
        work_units,
        test_setups,
        profile.maxProcessCount;
        coverage_root_uris = coalesce(profile.coverageRootUris, nothing),
        token = token
    )

    # ... rest as before (return CreateTestRunResponse)
end
```

### Callback registration

When creating the `TestItemController` in the JSONRPC layer, register callbacks that ignore the new `test_env_id` parameter:

```julia
on_testitem_started = (testrun_id, testitem_id, test_env_id) -> begin
    JSONRPC.send(endpoint, notficiationTypeTestItemStarted,
        TestItemControllerProtocol.TestItemStartedParams(
            testRunId = testrun_id,
            testItemId = testitem_id
        ))
end
# Same pattern for passed, failed, errored, skipped — just drop test_env_id
```

---

## Changed: `TestItemDetail`

**File: `src/datatypes.jl`**

Remove the `timeout` field from `TestItemDetail`. Timeout is now a per-work-unit setting in `TestRunItem`, not a property of the test item definition.

```julia
struct TestItemDetail
    id::String
    uri::String
    label::String
    package_name::Union{Nothing,String}
    package_uri::Union{Nothing,String}
    project_uri::Union{Nothing,String}
    env_content_hash::Union{Nothing,String}
    option_default_imports::Bool
    test_setups::Vector{String}
    line::Int
    column::Int
    code::String
    code_line::Int
    code_column::Int
    # timeout removed — now in TestRunItem
end
```

Update all places that construct `TestItemDetail` to remove the timeout argument. Update places that read `item.timeout` to read from the `TestRunItem` instead.

---

## Changed: TestItemRunnerCore

**File: `TestItemRunnerCore/src/TestItemRunnerCore.jl`**

### Callback signatures

Update all callback lambdas to accept the new `test_env_id` parameter:

```julia
on_testitem_started = (testrun_id, testitem_id, test_env_id) -> nothing,
on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) -> begin
    # ... existing logic, but now can record which env the result is for
    push!(ctx.responses, (testitem=testitem, testenvironment=..., result=...))
end,
```

Currently `testenvironment` in responses is hardcoded to `ctx.environments[1]`. With the new API, look up the environment by `test_env_id` to record which environment the result belongs to.

### `execute_testrun` call

Update the call site to use the new signature:

```julia
env = TestItemControllers.TestEnvironment(
    i.name,           # id
    "julia",          # julia_cmd
    String[],         # julia_args
    missing,          # julia_num_threads
    Dict{String,Union{String,Nothing}}(
        k => v isa AbstractString ? string(v) : v === nothing ? nothing : string(v)
        for (k,v) in i.env
    ),
    i.coverage ? "Coverage" : "Normal"
)

work_units = [
    TestItemControllers.TestRunItem(
        id,
        env.id,
        Float64(timeout),
        :Info
    ) for id in keys(testitems_to_run_by_id)
]

ret = TestItemControllers.execute_testrun(
    tic,
    testrun_id,
    [env],
    collect(values(testitems_to_run_by_id)),
    work_units,
    test_setups,
    max_workers;
    coverage_root_uris = nothing,
    token = token,
)
```

---

## Test Changes

All existing tests that call `execute_testrun` or construct `TestProfile` will need updating to use the new types. The test structure should remain the same — just adapt to the new API shape. Search for `TestProfile` across test files and replace with `TestEnvironment` + `TestRunItem` construction.

Also search for callback registrations in test files and add the `test_env_id` parameter.

---

## Summary of All Files to Change

| File | Changes |
|------|---------|
| `src/datatypes.jl` | Add `TestEnvironment`, `TestRunItem`. Remove `TestProfile`. Remove `timeout` from `TestItemDetail`. |
| `src/testenvironment.jl` | Rename `TestEnvironment` → `ProcessEnv`. Keep hash/eq implementations. |
| `src/state.jl` | Update `TestRunState` fields. Update `TestProcessState.env` type to `ProcessEnv`. Add `_resolve_test_env_id` helper. |
| `src/messages.jl` | Replace all `TestEnvironment` type references with `ProcessEnv`. |
| `src/callbacks.jl` | Add `test_env_id` parameter to testitem callback signatures. |
| `src/testitemcontroller.jl` | New `execute_testrun` signature. Rename `_item_env` → `_item_process_env`. Change `remaining_items` → `remaining_work` with tuple keys. Update all item completion handlers, cancellation handler, stealing, completion check, timeout handling. Update `process_pool` and `precompiled_envs` types. |
| `src/jsonrpctestitemcontroller.jl` | Adapt to new `execute_testrun` API. Translate between old JSONRPC protocol types and new internal types. Drop `test_env_id` in callback forwarding. |
| `src/json_protocol.jl` | **No changes** (backwards compatible). |
| `src/TestItemControllers.jl` | Update exports if needed. |
| `TestItemRunnerCore/src/TestItemRunnerCore.jl` | Update callback signatures, update `execute_testrun` call site, update response recording. |
| `test/` | Update all test files that construct `TestProfile` or register callbacks. |

---

## What This Plan Does NOT Cover (Phase 2)

- Removing the single-env runtime guard
- The process scheduler (dynamic allocation of processes across environments within `max_processes` budget)
- Idle process reclamation (killing processes for completed envs to free slots for pending envs)
- Retry logic (re-queuing failed work units based on `TestRunItem.max_retries`)
- Exposing multi-env via the JSONRPC protocol
