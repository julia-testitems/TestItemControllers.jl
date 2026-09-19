@testitem "Test with module setup" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Filter to the test item that uses ConfigSetup
    setup_items = filter(i -> i.label == "transform with module setup", discovered.items)
    @test length(setup_items) == 1
    @test "ConfigSetup" in setup_items[1].test_setups

    # Include the necessary setups
    relevant_setups = filter(s -> s.name in setup_items[1].test_setups, discovered.setups)
    @test length(relevant_setups) >= 1

    result = TestHelpers.run_testrun(setup_items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)

    @test length(passed_events) == 1
    @test length(failed_events) == 0
    @test length(errored_events) == 0
end

@testitem "Test with snippet setup" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Filter to the test item that uses SharedSnippet
    snippet_items = filter(i -> i.label == "uses snippet setup", discovered.items)
    @test length(snippet_items) == 1

    result = TestHelpers.run_testrun(snippet_items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    @test length(passed_events) == 1
end

@testitem "A test item with a module setup sees its own @__DIR__" setup=[TestHelpers] begin
    # A `@testmodule` is evaluated by whichever item reaches it first, and the test process
    # used to evaluate the item's own body with the *setup's* file path afterwards, so
    # `@__DIR__` and `@__FILE__` named the setup's directory. Every later item on that
    # process reuses the already-evaluated module and is unaffected, which is what made this
    # look order-dependent.
    #
    # Hence exactly one item per run here: `run_testrun` builds a fresh controller, so the
    # fixture item gets a fresh process in which `ConfigSetup` is unevaluated. Batching the
    # two fixture items into one run would let the second pass against the broken code.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "nested item resolves its own dir", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)

    if length(passed_events) != 1
        TestHelpers.dump_run("nested item did not pass", result; items=items)
    end

    @test length(passed_events) == 1
    @test length(failed_events) == 0
    @test length(errored_events) == 0
end

@testitem "A failure in a test item with a module setup is located at the item's file" setup=[TestHelpers] begin
    # The location half of the same bug: the frames of the item's own top-level code carried
    # the setup's file, so a failure was reported against `setup_tests.jl`. As above, this
    # only bites the item that evaluates the `@testmodule`, so it must run alone.
    using TestItemControllers: uri2filepath

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "nested item fails in its own file", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)

    if length(failed_events) != 1
        TestHelpers.dump_run("nested item did not fail as expected", result; items=items)
    end

    @test length(failed_events) == 1

    messages = failed_events[1].messages
    @test length(messages) >= 1
    @test messages[1].uri !== nothing
    @test basename(uri2filepath(messages[1].uri)) == "nested_tests.jl"
end
