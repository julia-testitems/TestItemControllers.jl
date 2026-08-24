@testitem "Heartbeat warns on a quiet run and fails a silent one" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, TestRunState,
        TestEnvironment, TestItemDetail, TestRunItem, TestSetupDetail, HeartbeatMsg,
        handle!, state, TestRunCancelled, TestRunCreated

    errored = Tuple{String,String}[]
    callbacks = ControllerCallbacks(;
        on_testitem_started = (args...) -> nothing,
        on_testitem_passed = (args...) -> nothing,
        on_testitem_failed = (args...) -> nothing,
        on_testitem_errored = (run_id, item_id, env_id, messages, duration, perf...) ->
            push!(errored, (item_id, messages[1].message)),
        on_testitem_skipped = (args...) -> nothing,
        on_append_output = (args...) -> nothing,
        on_attach_debugger = (args...) -> nothing,
    )

    # No reactor is running: the handler is driven directly, so the timing is simulated by
    # setting last_activity rather than by sleeping.
    c = TestItemController(callbacks; run_stall_seconds=10.0)
    try
        tr = TestRunState("stall-run", TestEnvironment[], TestItemDetail[], TestRunItem[],
            TestSetupDetail[], 1)
        c.test_runs["stall-run"] = tr

        # Fresh run: nothing happens.
        handle!(c, HeartbeatMsg())
        @test !tr.stall_warned
        @test state(tr.fsm) == TestRunCreated

        # Past one threshold: warned once, still running.
        tr.last_activity = time() - 11.0
        handle!(c, HeartbeatMsg())
        @test tr.stall_warned
        @test state(tr.fsm) == TestRunCreated

        # Activity resets the warning.
        tr.last_activity = time()
        tr.stall_warned = false
        handle!(c, HeartbeatMsg())
        @test !tr.stall_warned

        # A Debug run is exempt: paused at a breakpoint, silence is legitimate.
        debug_env = TestEnvironment("dbg-env", "julia", String[], nothing,
            Dict{String,Union{String,Nothing}}(), "Debug", "Pkg", "file:///pkg", nothing,
            nothing, nothing, false)
        tr_dbg = TestRunState("dbg-run", [debug_env], TestItemDetail[], TestRunItem[],
            TestSetupDetail[], 1)
        c.test_runs["dbg-run"] = tr_dbg
        tr_dbg.last_activity = time() - 1000.0
        handle!(c, HeartbeatMsg())
        @test !tr_dbg.stall_warned
        @test state(tr_dbg.fsm) == TestRunCreated

        # Past twice the threshold: the run is failed and its caller released.
        tr.last_activity = time() - 21.0
        handle!(c, HeartbeatMsg())
        @test state(tr.fsm) == TestRunCancelled
        @test isready(tr.completion_channel)
    finally
        # Stop the heartbeat timer.
        c.heartbeat_timer === nothing || close(c.heartbeat_timer)
    end
end

@testitem "A worker that never connects fails the run instead of hanging it" setup=[TestHelpers] begin
    # The CI hang in one sentence: a test process that is alive but will never send a
    # message again, while the run still has remaining work. Nothing item-scoped can fire —
    # no item ever started — and before the heartbeat the reactor idled on it forever
    # (6 hours, until GitHub killed the job). Simulate it exactly: `-e "sleep(600)"` makes
    # the child treat the test-server script as ARGS and just sleep, so it launches fine and
    # never connects.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label == "add works", discovered.items)
    @test length(items) == 1

    started = time()
    result = TestHelpers.run_testrun(items, discovered.setups, discovered;
        max_procs=1,
        julia_args=["-e", "sleep(600)"],
        run_stall_seconds=5,
        timeout=300,
    )
    elapsed = time() - started

    terminal = filter(e -> e.event in (:errored, :failed, :passed, :skipped), result.events)
    @test length(terminal) == 1
    @test terminal[1].event == :errored
    @test occursin("stalled", terminal[1].messages[1].message)
    # Failed by the heartbeat (≈2×5 s + one beat), not by the 300 s harness timeout and
    # nowhere near the 600 s the wedged worker would sleep.
    @test elapsed < 120
end
