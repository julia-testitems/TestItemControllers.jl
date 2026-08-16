@testitem "GC between test items does not deadlock the test process" setup=[TestHelpers] begin
    # Regression test for a deadlock that shipped with the watchdog and sat on the common
    # path: `gc_between_testitems` defaults on for multi-process runs.
    #
    # The watchdog thread runs a loop that neither allocates nor yields, paced by
    # `Libc.systemsleep` (a plain `ccall`). Without an explicit `GC.safepoint()` the thread
    # never becomes collectable, so `GC.gc(true)` — which stops the world and waits for
    # every thread — blocks forever on the first inter-item collection. The process then
    # stops consuming items and the run wedges with no diagnostic at all.
    #
    # Several passing items matter: the deadlock strikes on the *second*, after the first
    # has triggered a collection. The run timeout turns a regression into a failure rather
    # than a hang.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works", "output test"), discovered.items)
    @test length(items) == 3

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        gc_between_testitems=true, timeout=180,
    )

    passed = filter(e -> e.event == :passed, result.events)
    @test length(passed) == 3
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))
end

@testitem "GC between test items stays off unless requested" setup=[TestHelpers] begin
    # The flag has to actually reach the test process for the test above to mean anything,
    # so pin both directions rather than only the enabled one.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "add works", discovered.items)

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        gc_between_testitems=false, timeout=600,
    )

    @test length(filter(e -> e.event == :passed, result.events)) == 1
end

@testitem "A timed-out test item leaves hang diagnostics in its output" setup=[TestHelpers] begin
    # The point of the watchdog: an item killed for running too long should leave a stack
    # behind rather than a bare "timed out" line. The dump is written to a private file by a
    # dedicated thread and folded into the item's output by the controller, so asserting on
    # the captured output exercises that whole path.
    #
    # `slow test` sleeps, which still yields — the case the watchdog can serve. An item that
    # neither allocates nor yields never reaches a safepoint and is explicitly out of scope;
    # the controller's own timeout remains the backstop there.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    slow = only(filter(i -> i.label == "slow test", discovered.items))

    result = TestHelpers.run_testrun(
        [slow], discovered.setups, discovered;
        timeout=180, item_timeouts=Dict(slow.id => 5.0),
    )

    errored = filter(e -> e.testitem_id == slow.id && e.event == :errored, result.events)
    @test length(errored) == 1

    output = get(result.outputs, slow.id, "")
    @test occursin("Hang diagnostics", output)
    # The header carries the item and the process context, which is what makes the dump
    # actionable when it turns up in a CI log.
    @test occursin(slow.label, output)
    @test occursin("Julia ", output)
end

@testitem "A test process over the memory threshold is recycled without losing items" setup=[TestHelpers] begin
    # The worker checks system memory after each item and, when over threshold, exits
    # cleanly with a distinguished code instead of being killed. The controller has to treat
    # that as a recycle — redistributing un-started items through the existing termination
    # path — rather than as a crash.
    #
    # A threshold of 0.0 means "always over", so every item recycles its process. That is
    # the harshest form of the path, and it pins the invariant that matters: every item
    # still reports exactly once, and nothing is reported as an error.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works", "output test"), discovered.items)

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        memory_threshold=0.0, timeout=300,
    )

    passed = filter(e -> e.event == :passed, result.events)
    @test Set(e.testitem_id for e in passed) == Set(i.id for i in items)
    @test length(passed) == length(items)
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))

    # Without this the test is vacuous: three items pass whether or not a single recycle
    # happened. Each item recycles its process, so the run needs more processes than the
    # one it started with.
    created = filter(e -> e.event == :process_created, result.process_events)
    @test length(created) > 1
end

@testitem "A recycling test process exits without stranding the controller" setup=[TestHelpers] begin
    # Regression test. `exit` tears the runtime down from the calling thread, so exiting
    # while the watchdog was still running Julia code raced it: on Windows that surfaced as
    # an `EXCEPTION_ACCESS_VIOLATION` inside the JIT, and otherwise as a process that never
    # exited — which stranded the controller in shutdown, waiting for a termination message
    # that could not arrive. The run itself completed, so only the shutdown hung, which is
    # why the three-item test above did not catch it.
    #
    # Two items on one process is the shape that reproduced: exactly one recycle, then a
    # replacement that finishes the run and is shut down normally. The assertion that
    # matters is simply that this returns at all.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(items) == 2

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        memory_threshold=0.0, max_procs=1, timeout=180,
    )

    @test length(filter(e -> e.event == :passed, result.events)) == 2
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))
end
