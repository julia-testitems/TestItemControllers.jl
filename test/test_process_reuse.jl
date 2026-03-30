@testitem "Test process reused across runs" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    passing_items = filter(i -> i.label == "add works", discovered.items)
    @test length(passing_items) == 1

    process_created_ids = String[]
    process_created_lock = ReentrantLock()

    events1 = NamedTuple[]
    events1_lock = ReentrantLock()
    events2 = NamedTuple[]
    events2_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> begin
            lock(events1_lock) do; push!(events1, (event=:passed,)); end
            lock(events2_lock) do; push!(events2, (event=:passed,)); end
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(process_created_lock) do
            push!(process_created_ids, id)
        end,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    # First test run
    work_units1 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in passing_items]
    execute_testrun(
        controller,
        string(UUIDs.uuid4()),
        [test_env],
        passing_items,
        work_units1,
        discovered.setups,
        1,
        nothing
    )

    @test length(filter(e -> e.event == :passed, events1)) >= 1
    first_run_process_count = lock(process_created_lock) do
        length(process_created_ids)
    end
    @test first_run_process_count == 1

    # Clear events for second run
    lock(events2_lock) do; empty!(events2); end

    # Second test run — should reuse the existing process
    work_units2 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in passing_items]
    execute_testrun(
        controller,
        string(UUIDs.uuid4()),
        [test_env],
        passing_items,
        work_units2,
        discovered.setups,
        1,
        nothing
    )

    @test length(filter(e -> e.event == :passed, events2)) >= 1

    second_run_process_count = lock(process_created_lock) do
        length(process_created_ids)
    end
    # Process count should still be 1 — the process was reused
    @test second_run_process_count == 1

    @info "[test] Process reuse: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="process-reuse-controller")
end
