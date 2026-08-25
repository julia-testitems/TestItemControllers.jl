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
    c = TestItemController(callbacks; run_stall_warn_seconds=10.0, run_stall_seconds=20.0)
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

        # Past the failing threshold: the run is failed and its caller released.
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

@testitem "The default heartbeat warns but never fails a run" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, TestRunState,
        TestEnvironment, TestItemDetail, TestRunItem, TestSetupDetail, HeartbeatMsg,
        handle!, state, TestRunCreated

    # The failing heartbeat is opt-in. Every default-on kill this controller has shipped
    # eventually fired on a legitimate run — most recently mid-precompile on a cold CI
    # cache — so the default may diagnose a stall, loudly, but never act on it.
    noop = (args...) -> nothing
    errored = String[]
    callbacks = ControllerCallbacks(;
        on_testitem_started = noop, on_testitem_passed = noop, on_testitem_failed = noop,
        on_testitem_errored = (run_id, item_id, env_id, messages, duration, perf...) ->
            push!(errored, item_id),
        on_testitem_skipped = noop, on_append_output = noop, on_attach_debugger = noop,
    )

    c = TestItemController(callbacks)
    try
        # The warn-only heartbeat is armed by default.
        @test c.run_stall_seconds === nothing
        @test c.run_stall_warn_seconds == 300.0
        @test c.heartbeat_timer !== nothing

        tr = TestRunState("default-run", TestEnvironment[], TestItemDetail[], TestRunItem[],
            TestSetupDetail[], 1)
        c.test_runs["default-run"] = tr

        # However stale the run is, the default configuration warns and does nothing else.
        tr.last_activity = time() - 1.0e6
        handle!(c, HeartbeatMsg())
        @test tr.stall_warned
        @test state(tr.fsm) == TestRunCreated
        @test !isready(tr.completion_channel)
        @test isempty(errored)
    finally
        c.heartbeat_timer === nothing || close(c.heartbeat_timer)
    end

    # Both thresholds off: no heartbeat timer at all.
    c2 = TestItemController(callbacks; run_stall_warn_seconds=nothing)
    try
        @test c2.heartbeat_timer === nothing
    finally
        c2.heartbeat_timer === nothing || close(c2.heartbeat_timer)
    end

    # Opting in to the fail threshold arms the timer even with the warning off.
    c3 = TestItemController(callbacks; run_stall_warn_seconds=nothing, run_stall_seconds=15.0)
    try
        @test c3.heartbeat_timer !== nothing
    finally
        c3.heartbeat_timer === nothing || close(c3.heartbeat_timer)
    end
end

@testitem "A busy test process is progress, however quiet the reactor is" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, TestRunState,
        TestEnvironment, TestItemDetail, TestRunItem, TestSetupDetail, HeartbeatMsg,
        TestProcessState, ProcessEnv, BUSY_PROCESS_PHASES, ProcessStarting,
        ProcessActivatingEnv, ProcessWaitingForPrecompile, ProcessRevising, ProcessRunning,
        ProcessReviseOrStart, ProcessConfiguringTestRun, ProcessReadyToRun,
        handle!, state, transition!, TestRunCancelled, TestRunCreated

    # The regression this guards: on a cold cache every leg of
    # ModelPredictiveControl.jl run 32794123684 sat in `ProcessActivatingEnv` for 660-1100s
    # while its worker precompiled, which produces no reactor message at all. Two of them
    # were killed mid-precompile with every one of their 98 items errored.
    noop = (args...) -> nothing
    errored = String[]
    callbacks = ControllerCallbacks(;
        on_testitem_started = noop, on_testitem_passed = noop, on_testitem_failed = noop,
        on_testitem_errored = (run_id, item_id, env_id, messages, duration, perf...) ->
            push!(errored, messages[1].message),
        on_testitem_skipped = noop, on_append_output = noop, on_attach_debugger = noop,
    )

    env = TestEnvironment("env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Normal", "Pkg", "file:///pkg", nothing,
        nothing, nothing, false)

    function fresh_controller()
        c = TestItemController(callbacks; run_stall_seconds=10.0)
        tr = TestRunState("run-1", [env], TestItemDetail[], TestRunItem[],
            TestSetupDetail[], 1)
        c.test_runs["run-1"] = tr
        ps = TestProcessState("proc-1", ProcessEnv(env))
        ps.testrun_id = "run-1"
        c.test_processes["proc-1"] = ps
        return (c, tr, ps)
    end

    # The FSM only accepts legal transitions, so each phase is reached the way a real
    # process reaches it.
    PATH_TO = Dict(
        ProcessRevising              => [ProcessReviseOrStart, ProcessRevising],
        ProcessWaitingForPrecompile  => [ProcessStarting, ProcessWaitingForPrecompile],
        ProcessActivatingEnv         => [ProcessStarting, ProcessActivatingEnv],
        ProcessRunning               => [ProcessStarting, ProcessActivatingEnv,
                                         ProcessConfiguringTestRun, ProcessReadyToRun,
                                         ProcessRunning],
    )
    drive_to!(ps, phase) = foreach(p -> transition!(ps.fsm, p), PATH_TO[phase])

    # Every phase in which the controller is waiting on the worker exempts the run, no
    # matter how far past twice the threshold it is.
    @test issetequal(keys(PATH_TO), BUSY_PROCESS_PHASES)
    for phase in BUSY_PROCESS_PHASES
        c, tr, ps = fresh_controller()
        try
            drive_to!(ps, phase)
            @test state(ps.fsm) == phase
            tr.last_activity = time() - 10_000.0
            handle!(c, HeartbeatMsg())
            @test state(tr.fsm) == TestRunCreated
            @test !tr.stall_warned
            # The clock is restarted, not merely skipped: when the operation ends the run
            # gets the whole threshold again before anything calls it stalled.
            @test time() - tr.last_activity < 1.0
        finally
            c.heartbeat_timer === nothing || close(c.heartbeat_timer)
        end
    end

    # `ProcessStarting` is deliberately *not* exempt: a worker that launches and never
    # connects is the hang the heartbeat exists to catch, and it looks exactly like this.
    c, tr, ps = fresh_controller()
    try
        @test !(ProcessStarting in BUSY_PROCESS_PHASES)
        transition!(ps.fsm, ProcessStarting)
        tr.last_activity = time() - 21.0
        handle!(c, HeartbeatMsg())
        @test state(tr.fsm) == TestRunCancelled
    finally
        c.heartbeat_timer === nothing || close(c.heartbeat_timer)
    end

    # A process belonging to a *different* run does not shield this one.
    c, tr, ps = fresh_controller()
    try
        drive_to!(ps, ProcessActivatingEnv)
        ps.testrun_id = "some-other-run"
        tr.last_activity = time() - 21.0
        handle!(c, HeartbeatMsg())
        @test state(tr.fsm) == TestRunCancelled
    finally
        c.heartbeat_timer === nothing || close(c.heartbeat_timer)
    end
end

@testitem "The stall explanation says what the processes were doing" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, TestRunState,
        TestEnvironment, TestItemDetail, TestRunItem, TestSetupDetail, HeartbeatMsg,
        TestProcessState, ProcessEnv, ProcessStarting, handle!, transition!

    # The first version of this message asserted a test process "most likely died or
    # wedged", which was flatly wrong every time the heartbeat misfired. Whatever it
    # concludes, it now has to show its working.
    noop = (args...) -> nothing
    messages = String[]
    callbacks = ControllerCallbacks(;
        on_testitem_started = noop, on_testitem_passed = noop, on_testitem_failed = noop,
        on_testitem_errored = (run_id, item_id, env_id, msgs, duration, perf...) ->
            push!(messages, msgs[1].message),
        on_testitem_skipped = noop, on_append_output = noop, on_attach_debugger = noop,
    )

    env = TestEnvironment("env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Normal", "Pkg", "file:///pkg", nothing,
        nothing, nothing, false)
    item = TestItemDetail("item-1", "file:///pkg/test/a.jl", "item-1", "Pkg", "file:///pkg",
        true, String[], 1, 1, "@test true", 1, 1)

    c = TestItemController(callbacks; run_stall_seconds=10.0)
    try
        tr = TestRunState("run-1", [env], [item],
            [TestRunItem("item-1", "env-1", nothing, :Info)], TestSetupDetail[], 1)
        tr.remaining_work[("item-1", "env-1")] = TestRunItem("item-1", "env-1", nothing, :Info)
        c.test_runs["run-1"] = tr

        ps = TestProcessState("proc-1", ProcessEnv(env))
        ps.testrun_id = "run-1"
        transition!(ps.fsm, ProcessStarting)
        c.test_processes["proc-1"] = ps

        tr.last_activity = time() - 21.0
        handle!(c, HeartbeatMsg())

        @test length(messages) == 1
        @test occursin("no worker was busy", messages[1])
        @test occursin("proc-1", messages[1])
        @test occursin("ProcessStarting", messages[1])
    finally
        c.heartbeat_timer === nothing || close(c.heartbeat_timer)
    end
end
