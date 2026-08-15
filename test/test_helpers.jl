@testmodule TestHelpers begin
    using JuliaWorkspaces
    using Test
    using TestItemControllers: TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail, TestItemController,
        execute_testrun, shutdown, TestItemControllerProtocol, ControllerCallbacks, JSON

    const TESTDATA_DIR = normpath(joinpath(@__DIR__, "..", "testdata"))

    const _HELPER_LOCK = ReentrantLock()

    const _JULIAUP_CHANNELS = Ref{Union{Nothing,Set{String}}}(nothing)

    """
        installed_juliaup_channels()

    The set of juliaup channel names installed on this machine. Throws if juliaup cannot be
    queried; callers that want to degrade gracefully should wrap this in a `try`. Memoized,
    so a worker running many per-version test items only shells out once.
    """
    function installed_juliaup_channels()
        lock(_HELPER_LOCK) do
            cached = _JULIAUP_CHANNELS[]
            cached === nothing || return cached

            config = try
                JSON.parse(read(`juliaup api getconfig1`, String))
            catch e
                error("Failed to query juliaup. Is juliaup installed? Error: $e")
            end

            channels = Set{String}()
            push!(channels, config["DefaultChannel"]["Name"])
            for ch in get(config, "OtherChannels", [])
                push!(channels, ch["Name"])
            end

            _JULIAUP_CHANNELS[] = channels
            return channels
        end
    end

    const _DEPOT_ENVS = Dict{String,Dict{String,Union{String,Nothing}}}()

    """
        isolated_depot_env(version)

    An environment overlay that points a test process at a *private, writable* depot layered
    on top of that Julia's own default depots.

    Per-version test items run concurrently, and every worker run reaches Pkg (`Pkg.develop`
    on Julia <= 1.10, `Pkg.instantiate` inside TestEnv), which rewrites depot-wide usage logs
    such as `logs/manifest_usage.toml` without locking on older Pkg versions. Making the
    private depot `DEPOT_PATH[1]` sends every *write* — new precompile caches, installs, usage
    logs — there instead of into the shared depot.

    Reads are unaffected: Julia searches all depot entries for cache files and packages, so
    existing `~/.julia/compiled/vX.Y` entries stay warm.

    The default entries are queried from the target Julia rather than guessed, because setting
    `JULIA_DEPOT_PATH` *replaces* the whole list — dropping `<BINDIR>/../share/julia` would
    force a from-source recompile of the shipped stdlib caches — and the trailing-separator
    "append the defaults" syntax does not exist before Julia 1.10.
    """
    function isolated_depot_env(version::AbstractString)
        lock(_HELPER_LOCK) do
            get!(_DEPOT_ENVS, version) do
                root = get(ENV, "TIC_TEST_DEPOT_ROOT", joinpath(homedir(), ".julia", "tic-test-depots"))
                private = joinpath(root, "v$(version)")
                mkpath(private)

                sep = Sys.iswindows() ? ";" : ":"
                code = "print(join(DEPOT_PATH, Sys.iswindows() ? \";\" : \":\"))"
                defaults = readchomp(`julia +$version --startup-file=no --history-file=no -e $code`)

                Dict{String,Union{String,Nothing}}(
                    "JULIA_DEPOT_PATH" => isempty(defaults) ? private : string(private, sep, defaults)
                )
            end
        end
    end

    const _BASIC_PACKAGE = Ref{Any}(nothing)

    """
        basic_package_discovery()

    Discovery result for `testdata/BasicPackage`, memoized. Rediscovering per version would
    spin up a fresh `JuliaWorkspaces` workspace for every one of the per-version test items
    that share a worker, which is pure overhead — the input never changes.
    """
    function basic_package_discovery()
        lock(_HELPER_LOCK) do
            cached = _BASIC_PACKAGE[]
            cached === nothing || return cached

            discovered = discover_test_items(joinpath(TESTDATA_DIR, "BasicPackage"))
            _BASIC_PACKAGE[] = discovered
            return discovered
        end
    end

    """
        check_julia_version(version)

    Run the four canonical `BasicPackage` test items under the given juliaup channel and assert
    the expected pass/fail/error breakdown. Shared by the per-version `:comprehensive_platform`
    test items.
    """
    function check_julia_version(version::AbstractString)
        # 1.4 does not run on macOS.
        Sys.isapple() && version == "1.4" && return

        version in installed_juliaup_channels() ||
            error("Julia $version is not installed. Install it with: juliaup add $version")

        discovered = basic_package_discovery()

        target_labels = ("add works", "greet works", "failing test", "erroring test")
        items = filter(i -> i.label in target_labels, discovered.items)
        @test length(items) == 4

        result = run_testrun(
            items, discovered.setups, discovered;
            julia_cmd="julia",
            julia_args=["+$version"],
            timeout=600,
            env=isolated_depot_env(version)
        )

        passed_events = filter(e -> e.event == :passed, result.events)
        failed_events = filter(e -> e.event == :failed, result.events)
        errored_events = filter(e -> e.event == :errored, result.events)
        skipped_events = filter(e -> e.event == :skipped, result.events)

        @test length(passed_events) == 2
        @test length(failed_events) == 1
        @test length(failed_events[1].messages) >= 1
        @test length(errored_events) == 1
        @test length(errored_events[1].messages) >= 1
        @test occursin("intentional error", errored_events[1].messages[1].message)
        @test length(skipped_events) == 0

        return
    end

    """
        timed_wait(task, timeout_secs; label="task")

    Wait for `task` to finish, but error with a descriptive message if it
    takes longer than `timeout_secs`. This prevents tests from hanging
    indefinitely.
    """
    function timed_wait(task::Task, timeout_secs::Real; label::String="task")
        timed_out = Ref(false)
        timer = Timer(timeout_secs)
        @async begin
            wait(timer)
            if !istaskdone(task)
                timed_out[] = true
                @warn "HANG DETECTED: $(label) did not complete within $(timeout_secs)s"
                # Print stack traces of all tasks to aid debugging
                try
                    Base.throwto(task, ErrorException("Test timed out: $(label) exceeded $(timeout_secs)s"))
                catch
                end
            end
        end
        wait(task)
        close(timer)
        # The task's own try-catch may swallow the throwto exception, so
        # check explicitly whether the timeout fired and fail loudly.
        if timed_out[]
            error("timed_wait exceeded timeout: $(label) did not complete within $(timeout_secs)s")
        end
    end

    # `position_at` used to return a `(line, column)` tuple and now returns a
    # `JuliaWorkspaces.Position`. Accept either.
    _line(pos) = hasproperty(pos, :line) ? pos.line : pos[1]
    _column(pos) = hasproperty(pos, :column) ? pos.column : pos[2]

    function discover_test_items(pkg_path::String)
        jw = workspace_from_folders([pkg_path])
        td_dict = get_test_items(jw)

        items = TestItemDetail[]
        setups = TestSetupDetail[]
        pkg_name = nothing
        pkg_uri = nothing
        proj_uri = nothing
        content_hash = nothing

        for (file_uri, td) in td_dict
            for ti in td.testitems
                env = get_test_env(jw, ti.uri)
                tf = get_text_file(jw, ti.uri)
                pos = position_at(tf.content, first(ti.range))
                code_pos = position_at(tf.content, first(ti.code_range))

                # Capture package info from first item with a package
                if pkg_name === nothing && env.package_name !== nothing
                    pkg_name = env.package_name
                    pkg_uri = env.package_uri === nothing ? nothing : string(env.package_uri)
                    proj_uri = env.project_uri === nothing ? nothing : string(env.project_uri)
                    content_hash = env.env_content_hash
                end

                push!(items, TestItemDetail(
                    ti.id,                                    # id
                    string(ti.uri),                           # uri
                    ti.name,                                  # label
                    env.package_name === nothing ? "" : env.package_name,  # package_name
                    env.package_uri === nothing ? "" : string(env.package_uri),  # package_uri
                    ti.option_default_imports,                 # option_default_imports
                    String[string(s) for s in ti.option_setup],  # test_setups
                    _line(pos),                                # line
                    _column(pos),                              # column
                    ti.code,                                  # code
                    _line(code_pos),                           # code_line
                    _column(code_pos),                         # code_column
                ))
            end

            for ts in td.testsetups
                env = get_test_env(jw, ts.uri)
                env.package_uri === nothing && continue
                tf = get_text_file(jw, ts.uri)
                pos = position_at(tf.content, first(ts.range))

                push!(setups, TestSetupDetail(
                    string(env.package_uri),
                    string(ts.name),
                    string(ts.kind),
                    string(ts.uri),
                    _line(pos),
                    _column(pos),
                    ts.code
                ))
            end
        end

        return (items=items, setups=setups, package_name=pkg_name, package_uri=pkg_uri, project_uri=proj_uri, env_content_hash=content_hash)
    end

    # Returns a copy of `item` carrying a `skip` option. Discovery does not supply one yet —
    # `option_skip` reaches `TestItemDetail` from JuliaWorkspaces, which is stream S1 — so
    # tests for the test-process side of `skip` set it here instead.
    function with_skip(item::TestItemDetail, skip::Union{Bool,String})
        return TestItemDetail(
            item.id,
            item.uri,
            item.label,
            item.package_name,
            item.package_uri,
            item.option_default_imports,
            item.test_setups,
            item.line,
            item.column,
            item.code,
            item.code_line,
            item.code_column,
            skip,
        )
    end

    function make_test_environment(; mode="Run", julia_cmd=joinpath(Sys.BINDIR, "julia"), julia_args=String[], env=Dict{String,Union{String,Nothing}}(), package_name="", package_uri="", project_uri=nothing, env_content_hash=nothing)
        TestEnvironment(
            "test-env-1",
            julia_cmd,
            julia_args,
            nothing,
            env,
            mode,
            package_name,
            package_uri,
            project_uri,
            env_content_hash
        )
    end

    function _env_kwargs(discovered)
        (; package_name=something(discovered.package_name, ""),
           package_uri=something(discovered.package_uri, ""),
           project_uri=discovered.project_uri,
           env_content_hash=discovered.env_content_hash)
    end

    function run_testrun(discovered::NamedTuple; kwargs...)
        run_testrun(discovered.items, discovered.setups; _env_kwargs(discovered)..., kwargs...)
    end

    function run_testrun(items, setups, discovered::NamedTuple; kwargs...)
        run_testrun(items, setups; _env_kwargs(discovered)..., kwargs...)
    end

    # `n_runs > 1` executes that many test runs back-to-back against **one** controller, so
    # the second run gets the pooled, already-warm test process of the first. `runs` in the
    # returned value holds the per-run events and output; `events`/`outputs` are the union
    # across runs, which is what a single-run caller wants.
    function run_testrun(items, setups; mode="Run", max_procs=1, timeout=300, coverage_root_uris=nothing, log_level=:Debug, julia_cmd=joinpath(Sys.BINDIR, "julia"), julia_args=String[], env=Dict{String,Union{String,Nothing}}(), item_timeouts=Dict{String,Float64}(), package_name="", package_uri="", project_uri=nothing, env_content_hash=nothing, n_runs=1, gc_between_testitems=nothing, memory_threshold=nothing)
        events = NamedTuple[]
        events_lock = ReentrantLock()
        push_event!(e) = lock(events_lock) do
            push!(events, e)
        end

        outputs = Dict{Union{Nothing,String},String}()
        outputs_lock = ReentrantLock()
        push_output!(item_id, output) = lock(outputs_lock) do
            outputs[item_id] = get(outputs, item_id, "") * output
        end

        process_events = NamedTuple[]
        process_events_lock = ReentrantLock()
        push_process_event!(e) = lock(process_events_lock) do
            push!(process_events, e)
        end

        callbacks = ControllerCallbacks(
            on_testitem_started = (run_id, item_id, test_env_id) -> push_event!((event=:started, testrun_id=run_id, testitem_id=item_id)),
            on_testitem_passed = (run_id, item_id, test_env_id, duration, perf=nothing) -> push_event!((event=:passed, testrun_id=run_id, testitem_id=item_id, duration=duration, perf=perf)),
            on_testitem_failed = (run_id, item_id, test_env_id, messages, duration, perf=nothing) -> push_event!((event=:failed, testrun_id=run_id, testitem_id=item_id, messages=messages, duration=duration, perf=perf)),
            on_testitem_errored = (run_id, item_id, test_env_id, messages, duration, perf=nothing) -> push_event!((event=:errored, testrun_id=run_id, testitem_id=item_id, messages=messages, duration=duration, perf=perf)),
            on_testitem_skipped = (run_id, item_id, test_env_id, reason=nothing) -> push_event!((event=:skipped, testrun_id=run_id, testitem_id=item_id, reason=reason)),
            on_append_output = (run_id, item_id, test_env_id, output) -> push_output!(item_id, output),
            on_attach_debugger = (run_id, pipe_name) -> nothing,
            on_process_created = (id, test_env_id) -> push_process_event!((event=:process_created, id=id, test_env_id=test_env_id)),

            on_process_terminated = id -> push_process_event!((event=:process_terminated, id=id)),
            on_process_status_changed = (id, status) -> push_process_event!((event=:status_changed, id=id, status=status)),
            on_process_output = (id, output) -> nothing,
        )

        controller = TestItemController(callbacks; log_level=log_level)
        test_env = make_test_environment(; mode=mode, julia_cmd=julia_cmd, julia_args=julia_args, env=env, package_name=package_name, package_uri=package_uri, project_uri=project_uri, env_content_hash=env_content_hash)

        # Build work units from items
        work_units = [TestRunItem(item.id, test_env.id, get(item_timeouts, item.id, nothing), log_level) for item in items]

        controller_task = @async try
            run(controller)
        catch err
            @error "Controller run error" exception=(err, catch_backtrace())
        end

        coverage_result = nothing
        runs = NamedTuple[]

        for run_idx in 1:n_runs
            events_before = length(events)
            outputs_before = lock(outputs_lock) do
                copy(outputs)
            end

            testrun_id = string(UUIDs.uuid4())

            testrun_task = @async try
                coverage_result = execute_testrun(
                    controller,
                    testrun_id,
                    [test_env],
                    items,
                    work_units,
                    setups,
                    max_procs,
                    nothing;  # token
                    coverage_root_uris=coverage_root_uris,
                    gc_between_testitems=gc_between_testitems,
                    memory_threshold=memory_threshold
                )
            catch err
                @error "Test run error" exception=(err, catch_backtrace())
            end

            # Wait for test run with timeout
            timed_out = Ref(false)
            timer = Timer(timeout)
            @async begin
                wait(timer)
                if !istaskdone(testrun_task)
                    timed_out[] = true
                    @warn "Test run timed out after $(timeout)s, shutting down"
                    shutdown(controller)
                end
            end

            wait(testrun_task)
            close(timer)

            if timed_out[]
                shutdown(controller)
                wait(controller_task)
                error("run_testrun timed out after $(timeout)s")
            end

            run_events = events[events_before+1:end]
            run_outputs = lock(outputs_lock) do
                Dict(k => v[length(get(outputs_before, k, ""))+1:end] for (k, v) in outputs)
            end
            push!(runs, (testrun_id=testrun_id, events=run_events, outputs=run_outputs))
        end

        shutdown(controller)
        wait(controller_task)

        return (events=events, process_events=process_events, coverage=coverage_result, outputs=outputs, runs=runs)
    end

    import UUIDs
end
