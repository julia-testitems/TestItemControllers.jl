@testitem "Controlled crash via exit()" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    crash_items = filter(i -> i.label == "exit crash", discovered.items)
    passing_items = filter(i -> i.label == "add works", discovered.items)
    @test length(crash_items) == 1
    @test length(passing_items) == 1

    # One process for both items, so the crash always lands on a process that still owes a
    # result for the other one.
    result = TestHelpers.run_testrun(vcat(crash_items, passing_items), discovered.setups, discovered; max_procs=1, timeout=600)

    crash_id = crash_items[1].id
    pass_id = passing_items[1].id
    terminal(id) = filter(e -> e.testitem_id == id && e.event in (:passed, :failed, :errored, :skipped), result.events)
    crash_terminal = terminal(crash_id)
    pass_terminal = terminal(pass_id)

    # Which item the crash is blamed on is the whole point of this item, and it turns on the
    # controller having actually read every result the process sent before it exited. A
    # result already on the wire but not yet consumed used to be discarded at the disconnect,
    # leaving `add works` on record as still-running: it was reported as the crashed item and
    # `exit crash`, which is the one that really called `exit()`, was redistributed to a
    # replacement instead. Assert both attributions, not just a count of passes — a bare
    # `Evaluated: 0 == 1` says nothing about what the item became instead.
    attributed_correctly = length(crash_terminal) == 1 && crash_terminal[1].event === :errored &&
        length(pass_terminal) == 1 && pass_terminal[1].event === :passed
    attributed_correctly || TestHelpers.dump_run("Controlled crash via exit()", result; items=discovered.items)

    @test length(crash_terminal) == 1
    @test !isempty(crash_terminal) && crash_terminal[1].event === :errored
    @test !isempty(crash_terminal) && crash_terminal[1].event === :errored &&
        any(m -> occursin("crashed", m.message), crash_terminal[1].messages)

    @test length(pass_terminal) == 1
    @test !isempty(pass_terminal) && pass_terminal[1].event === :passed

    # A replacement process may or may not be created depending on item execution order.
    # If the crash item ran first, the passing item needs a replacement process.
    # If the passing item ran first, it already completed and no replacement is needed.
    created = filter(e -> e.event == :process_created, result.process_events)
    @test length(created) >= 1

    # At least one process should have been terminated (the crashed one)
    terminated = filter(e -> e.event == :process_terminated, result.process_events)
    @test length(terminated) >= 1
end

@testitem "Hard crash via ccall abort" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs
    @info "[test] Hard crash via ccall abort: starting"

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Get the abort-crashing item and a passing item
    crash_items = filter(i -> i.label == "abort crash", discovered.items)
    passing_items = filter(i -> i.label == "greet works", discovered.items)
    @test length(crash_items) == 1
    @test length(passing_items) == 1

    all_items = vcat(crash_items, passing_items)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    process_events = NamedTuple[]
    process_events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:started, testitem_id=item_id))
        end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, testitem_id=item_id, messages=messages))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, testitem_id=item_id, messages=messages))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:skipped, testitem_id=item_id))
        end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(process_events_lock) do
            push!(process_events, (event=:process_created, id=id))
        end,
        on_process_terminated = id -> lock(process_events_lock) do
            push!(process_events, (event=:process_terminated, id=id))
        end,
        on_process_status_changed = (id, status) -> nothing,
        on_process_output = (id, output) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in all_items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    @info "[test] Hard crash via ccall abort: executing testrun"
    testrun_task = @async try
        execute_testrun(controller, testrun_id, [test_env], all_items, work_units, discovered.setups, 1, nothing)
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # On Windows, ccall(:abort) may trigger Windows Error Reporting which keeps the
    # process alive, preventing crash detection via pipe IO error.  Poll for the crash
    # item to reach a terminal state; if undetected after 60s, force shutdown.
    crash_id = crash_items[1].id
    pass_id = passing_items[1].id
    deadline = time() + 60
    crash_detected_early = Ref(false)
    while time() < deadline
        done = lock(events_lock) do
            any(e -> e.testitem_id == crash_id && e.event in (:errored, :skipped), events)
        end
        if done
            crash_detected_early[] = true
            break
        end
        sleep(1.0)
    end

    @info "[test] Hard crash via ccall abort: shutting down (crash_detected_early=$(crash_detected_early[]))"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="abort-crash-controller")
    if !istaskdone(testrun_task)
        TestHelpers.timed_wait(testrun_task, 600; label="abort-crash-testrun")
    end

    @info "[test] Hard crash via ccall abort: verifying results"

    # The crashing item should reach a terminal state (errored by crash handler, or skipped by shutdown)
    crash_terminal = lock(events_lock) do
        filter(e -> e.testitem_id == crash_id && e.event in (:errored, :skipped), events)
    end
    @test length(crash_terminal) >= 1

    # The passing item should have reached a terminal state
    pass_terminal = lock(events_lock) do
        filter(e -> e.testitem_id == pass_id && e.event in (:passed, :errored, :skipped), events)
    end
    @test length(pass_terminal) >= 1

    # At least one process should have been terminated
    terminated = lock(process_events_lock) do
        filter(e -> e.event == :process_terminated, process_events)
    end
    @test length(terminated) >= 1
end

@testitem "Single crash item is immediately errored" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Run ONLY the crashing item — it crashes, gets immediately errored, testrun completes.
    crash_items = filter(i -> i.label == "exit crash", discovered.items)
    @test length(crash_items) == 1

    result = TestHelpers.run_testrun(crash_items, discovered.setups, discovered; max_procs=1, timeout=600)

    crash_id = crash_items[1].id
    crash_errored = filter(e -> e.testitem_id == crash_id && e.event == :errored, result.events)
    created = filter(e -> e.event == :process_created, result.process_events)
    terminated = filter(e -> e.event == :process_terminated, result.process_events)

    length(crash_errored) == 1 && length(created) == 1 && length(terminated) == 1 ||
        TestHelpers.dump_run("Single crash item is immediately errored", result; items=discovered.items)

    @test length(crash_errored) == 1
    @test !isempty(crash_errored) && any(m -> occursin("crashed", m.message), crash_errored[1].messages)

    # Only 1 process should have been created (no replacement needed)
    @test length(created) == 1

    # The crashed process should have been terminated
    @test length(terminated) == 1
end

@testitem "A Julia command that cannot be spawned errors all test items" setup=[TestHelpers] begin
    using Logging: with_logger, Warn, Error
    using Test: TestLogger

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(items) == 2

    julia_cmd = joinpath(pkg_path, "nonexistent", "julia")

    # At shutdown, the controller waits up to 30 s for a test process that it did not
    # remove. A `shutdown_timeout` below that makes such a process fail the test.
    logger = TestLogger(min_level=Warn)
    result = with_logger(logger) do
        TestHelpers.run_testrun(items, discovered.setups, discovered; julia_cmd, max_procs=2, timeout=60, shutdown_timeout=10)
    end

    errored = filter(e -> e.event == :errored, result.events)
    @test sort([e.testitem_id for e in errored]) == sort([i.id for i in items])

    # The user is told why, not that the process crashed.
    @test all(errored) do e
        any(m -> occursin("Could not start the test process", m.message) && occursin("ENOENT", m.message), e.messages)
    end

    # A misconfigured `juliaCmd` is a user error. Under the crash-reporting logger VS Code
    # installs, anything logged at `Error` ends the controller and files a crash report.
    @test !any(r -> r.level >= Error, logger.logs)

    created = [e.id for e in result.process_events if e.event == :process_created]
    terminated = [e.id for e in result.process_events if e.event == :process_terminated]
    @test sort(terminated) == sort(created)
end

@testitem "A Julia command with arguments in it points the user at juliaArgs" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label == "add works", discovered.items)
    @test length(items) == 1

    # The controller runs the whole string as one program, so a juliaup channel written into
    # `juliaCmd` cannot be spawned.
    result = TestHelpers.run_testrun(items, discovered.setups, discovered; julia_cmd="julia +1.12", timeout=60, shutdown_timeout=10)

    errored = filter(e -> e.event == :errored, result.events)
    @test length(errored) == 1
    @test !isempty(errored) && any(errored[1].messages) do m
        occursin("Could not start the test process", m.message) && occursin("`juliaArgs`", m.message)
    end
end

@testitem "A Julia process that exits during startup errors its test items as crashed" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label == "add works", discovered.items)
    @test length(items) == 1

    # Julia rejects the unknown option and exits before it connects to the controller. The
    # process was spawned, so this is a crash and not a failure to start it.
    result = TestHelpers.run_testrun(items, discovered.setups, discovered; julia_args=["--no-such-option"], timeout=120, shutdown_timeout=10)

    errored = filter(e -> e.event == :errored, result.events)
    @test length(errored) == 1
    @test !isempty(errored) && any(m -> occursin("Test process crashed before running test item", m.message), errored[1].messages)
    @test !isempty(errored) && !any(m -> occursin("Could not start the test process", m.message), errored[1].messages)

    created = [e.id for e in result.process_events if e.event == :process_created]
    terminated = [e.id for e in result.process_events if e.event == :process_terminated]
    @test sort(terminated) == sort(created)
end

@testitem "The controller runs test items again after a Julia command could not be spawned" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label == "add works", discovered.items)
    @test length(items) == 1

    events = NamedTuple[]
    events_lock = ReentrantLock()
    push_event!(e) = lock(() -> push!(events, e), events_lock)

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> push_event!((event=:passed, testrun_id=run_id)),
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> push_event!((event=:failed, testrun_id=run_id)),
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> push_event!((event=:errored, testrun_id=run_id)),
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    env_kwargs = TestHelpers._env_kwargs(discovered)
    function run_once(test_env)
        testrun_id = string(UUIDs.uuid4())
        work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in items]
        run_task = @async execute_testrun(controller, testrun_id, [test_env], items, work_units, discovered.setups, 1, nothing)
        TestHelpers.timed_wait(run_task, 600; label="test run")
        return lock(() -> [e.event for e in events if e.testrun_id == testrun_id], events_lock)
    end

    bad_env = TestHelpers.make_test_environment(; env_kwargs..., julia_cmd=joinpath(pkg_path, "nonexistent", "julia"))
    @test run_once(bad_env) == [:errored]

    good_env = TestHelpers.make_test_environment(; env_kwargs...)
    @test run_once(good_env) == [:passed]

    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 60; label="controller shutdown")
end

@testitem "The startup-crash warning only reads fields the exception has" begin
    using TestItemControllers: TestProcessCrashException

    # `@warn` swallows an exception thrown while building its own log record: it prints
    # "Exception while generating log record" and the run carries on. So a mistyped field name
    # here is invisible until a process actually dies before it can connect — and then it
    # destroys the one message explaining why, which is the only record that path produces.
    # That is exactly what happened: `err.termsignal` against a field named `term_signal`.
    # Read the record back out of the source and check every field it names really exists.
    source = read(joinpath(pkgdir(TestItemControllers), "src", "testprocess.jl"), String)
    line = only(filter(l -> occursin("Test process crashed during startup", l), split(source, '\n')))

    fields = [Symbol(m.captures[1]) for m in eachmatch(r"\berr\.([A-Za-z_][A-Za-z0-9_]*)", line)]
    @test !isempty(fields)
    for f in fields
        @test f in fieldnames(TestProcessCrashException)
    end

    # And the record must still render for a crash that carries an exit code and a signal.
    err = TestProcessCrashException("tp-1", 139, 11, "boom")
    @test err.term_signal == 11
    @test err.exitcode == 139
end
