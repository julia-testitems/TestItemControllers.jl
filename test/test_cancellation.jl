@testitem "Cancel running test run" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())

    cs = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(cs)

    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async try
        execute_testrun(
            controller,
            testrun_id,
            [test_env],
            discovered.items,
            work_units,
            discovered.setups,
            1,
            token
        )
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Cancel immediately
    CancellationTokens.cancel(cs)

    # Wait for testrun to complete
    @info "[test] Cancel running test run: waiting for testrun"
    TestHelpers.timed_wait(testrun_task, 600; label="cancel-testrun")

    @info "[test] Cancel running test run: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="cancel-controller")

    # After cancellation, items should be skipped or already completed
    completed = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed) == length(discovered.items)
end

@testitem "Cancel test run during process activation does not crash controller" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()

    controller_error = Ref{Any}(nothing)

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    # Use multiple processes to increase likelihood of hitting intermediate states
    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    # --- First run: cancel immediately to trigger cancellation during activation ---
    cs1 = CancellationTokens.CancellationTokenSource()
    token1 = CancellationTokens.get_token(cs1)
    testrun_id1 = string(UUIDs.uuid4())
    work_units1 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        controller_error[] = err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task1 = @async try
        execute_testrun(
            controller,
            testrun_id1,
            [test_env],
            discovered.items,
            work_units1,
            discovered.setups,
            3,  # request multiple procs to maximize activation-phase coverage
            token1
        )
    catch err
        @error "Test run 1 error" exception=(err, catch_backtrace())
    end

    # Cancel while processes are likely still in activation/starting states
    CancellationTokens.cancel(cs1)

    @info "[test] Cancel during activation: waiting for first testrun"
    TestHelpers.timed_wait(testrun_task1, 600; label="cancel-activation-testrun1")

    # The controller reactor must still be running (no crash)
    @test !istaskdone(controller_task)
    @test controller_error[] === nothing

    # All items from the first run should be accounted for
    completed1 = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed1) == length(discovered.items)

    # --- Second run: verify controller is still functional ---
    empty!(events)
    testrun_id2 = string(UUIDs.uuid4())
    work_units2 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    testrun_task2 = @async try
        execute_testrun(
            controller,
            testrun_id2,
            [test_env],
            discovered.items,
            work_units2,
            discovered.setups,
            1,
            nothing  # no cancellation token — let it run to completion
        )
    catch err
        @error "Test run 2 error" exception=(err, catch_backtrace())
    end

    @info "[test] Cancel during activation: waiting for second testrun"
    # Run 2 executes every BasicPackage item — the 60s sleeper and the crash items included —
    # on a single process, so on a cold macOS-intel runner it genuinely approaches 300s. This
    # wait exists to catch a hang, not to budget the run.
    TestHelpers.timed_wait(testrun_task2, 900; label="cancel-activation-testrun2")

    @info "[test] Cancel during activation: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="cancel-activation-controller")

    # Second run should complete normally — every item passed or had a definitive result
    completed2 = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed2) == length(discovered.items)

    # Controller should have shut down cleanly, not crashed
    @test controller_error[] === nothing
end

@testitem "Cancel multi-process test run after item completes (steal race)" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    first_item_done = Ref(false)
    first_item_cond = Threads.Condition()
    controller_error = Ref{Any}(nothing)

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> begin
            lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> begin
            lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> begin
            lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())

    cs = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(cs)

    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        controller_error[] = err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async try
        execute_testrun(
            controller,
            testrun_id,
            [test_env],
            discovered.items,
            work_units,
            discovered.setups,
            3,  # multiple procs so stealing can be attempted
            token
        )
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Wait for at least one test item to complete before cancelling
    lock(first_item_cond) do
        while !first_item_done[]
            wait(first_item_cond)
        end
    end

    @info "[test] Cancel multi-process steal race: cancelling after first item completed"
    CancellationTokens.cancel(cs)

    @info "[test] Cancel multi-process steal race: waiting for testrun"
    TestHelpers.timed_wait(testrun_task, 600; label="cancel-steal-race-testrun")

    @info "[test] Cancel multi-process steal race: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="cancel-steal-race-controller")

    # Controller must not have crashed
    @test !istaskfailed(controller_task)
    @test controller_error[] === nothing

    # All items should be accounted for
    completed = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed) == length(discovered.items)
end

@testitem "A run whose token is already cancelled runs nothing" setup=[TestHelpers] begin
    # Regression: `CancellationTokens.register` invokes its callback immediately for an
    # already-cancelled token, so the bridge used to post `TestRunCancelledMsg` before the run
    # was in `controller.test_runs` — the handler's `haskey` guard then dropped it and the run
    # executed in full. Every item must be skipped and none of them may start.
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown,
        CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    record = (kind, id) -> lock(events_lock) do; push!(events, (event=kind, testitem_id=id)); end

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, env_id) -> record(:started, item_id),
        on_testitem_passed = (run_id, item_id, env_id, duration) -> record(:passed, item_id),
        on_testitem_failed = (run_id, item_id, env_id, messages, duration) -> record(:failed, item_id),
        on_testitem_errored = (run_id, item_id, env_id, messages, duration) -> record(:errored, item_id),
        on_testitem_skipped = (run_id, item_id, env_id) -> record(:skipped, item_id),
        on_append_output = (run_id, item_id, env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    cs = CancellationTokens.CancellationTokenSource()
    CancellationTokens.cancel(cs)   # cancelled *before* the run is submitted

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async execute_testrun(controller, string(UUIDs.uuid4()), [test_env],
        discovered.items, work_units, discovered.setups, 1, CancellationTokens.get_token(cs))

    TestHelpers.timed_wait(testrun_task, 600; label="precancelled-testrun")
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="precancelled-controller")

    @test count(e -> e.event === :skipped, events) == length(discovered.items)
    @test !any(e -> e.event in (:started, :passed, :failed, :errored), events)
end

@testitem "failfast stops the run at the first failure" setup=[TestHelpers] begin
    # Every item here fails, and all of them are handed to the one worker as a single batch,
    # so this only holds if the run is stopped on the reactor in the same step that records
    # the first failure. A stop requested by a consumer reacting to the callback is appended
    # to the reactor channel and loses to the next result already queued ahead of it.
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown,
        ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    always_failing = ["failing test", "failing test multiple", "erroring test"]
    items = filter(i -> i.label in always_failing, discovered.items)
    @test length(items) == length(always_failing)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    record = (kind, id) -> lock(events_lock) do; push!(events, (event=kind, testitem_id=id)); end

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, env_id) -> record(:started, item_id),
        on_testitem_passed = (run_id, item_id, env_id, duration) -> record(:passed, item_id),
        on_testitem_failed = (run_id, item_id, env_id, messages, duration) -> record(:failed, item_id),
        on_testitem_errored = (run_id, item_id, env_id, messages, duration) -> record(:errored, item_id),
        on_testitem_skipped = (run_id, item_id, env_id) -> record(:skipped, item_id),
        on_append_output = (run_id, item_id, env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async execute_testrun(controller, string(UUIDs.uuid4()), [test_env],
        items, work_units, discovered.setups, 1, nothing; failfast=true)

    TestHelpers.timed_wait(testrun_task, 600; label="failfast-testrun")
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 600; label="failfast-controller")

    terminal = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(terminal) == length(items)
    @test count(e -> e.event in (:failed, :errored), terminal) == 1
    @test count(e -> e.event === :skipped, terminal) == length(items) - 1
end
