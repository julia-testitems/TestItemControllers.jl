@testitem "A failing handler does not kill the reactor" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, ReactorMessage,
        ShutdownMsg, state, ControllerStopped

    noop_callbacks() = ControllerCallbacks(;
        on_testitem_started = (args...) -> nothing,
        on_testitem_passed = (args...) -> nothing,
        on_testitem_failed = (args...) -> nothing,
        on_testitem_errored = (args...) -> nothing,
        on_testitem_skipped = (args...) -> nothing,
        on_append_output = (args...) -> nothing,
        on_attach_debugger = (args...) -> nothing,
    )

    # A message no handler knows produces a MethodError inside the loop — the same shape as
    # any unforeseen handler failure. The loop used to die on it, silently converting every
    # in-flight run and every later `shutdown` into a permanent hang; now it logs and keeps
    # serving, so the shutdown that follows must still be processed and the loop must return.
    struct BoomMsg <: ReactorMessage end

    controller = TestItemController(noop_callbacks())
    reactor_task = @async run(controller)

    put!(controller.reactor_channel, BoomMsg())
    put!(controller.reactor_channel, ShutdownMsg())

    @test timedwait(() -> istaskdone(reactor_task), 60.0) === :ok
    @test !istaskfailed(reactor_task)
    @test state(controller.controller_fsm) == ControllerStopped
end

@testitem "A failure while shutting down still stops the controller" begin
    using TestItemControllers: TestItemController, ControllerCallbacks,
        ShutdownMsg, state, ControllerStopped

    noop_callbacks() = ControllerCallbacks(;
        on_testitem_started = (args...) -> nothing,
        on_testitem_passed = (args...) -> nothing,
        on_testitem_failed = (args...) -> nothing,
        on_testitem_errored = (args...) -> nothing,
        on_testitem_skipped = (args...) -> nothing,
        on_append_output = (args...) -> nothing,
        on_attach_debugger = (args...) -> nothing,
    )

    # If the shutdown path itself fails, carrying on would wait forever for termination
    # messages the broken handler never arranged — there the reactor force-stops instead.
    # Drive the failure handler directly, as the loop does after a ShutdownMsg handler throws.
    controller = TestItemController(noop_callbacks())
    stopped = TestItemControllers._handle_reactor_failure!(
        controller, ShutdownMsg(), ErrorException("boom"), Base.catch_backtrace())
    @test stopped === true
    @test state(controller.controller_fsm) == ControllerStopped
end
