# Regression test for a package whose `test/Manifest.toml` lists the package itself as a
# `path = ".."` dev entry (the layout `Pkg.develop(path=".")` inside `test/` produces).
#
# TestEnv merges the test manifest into the package's own manifest and used to error with
# "can not merge projects" on Julia <= 1.10 when the package's uuid was already present, see
# julia-vscode/julia-vscode#3832 and #3633. The Julia 1.11+ variant of the vendored TestEnv
# already tolerated that; the older variants carry the same guard now.

@testitem "Package with test/Manifest.toml dev-ing itself activates" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "TestManifestPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    @test length(discovered.items) == 1

    result = TestHelpers.run_testrun(discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)

    @test length(passed_events) == 1
    @test length(errored_events) == 0
    @test length(failed_events) == 0
end

# Same fixture on Julia 1.10, the newest release that runs the pre-1.11 TestEnv variant
# where the guard was missing.
@testitem "Package with test/Manifest.toml dev-ing itself activates on Julia 1.10" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    version = "1.10"
    version in TestHelpers.installed_juliaup_channels() ||
        error("Julia $version is not installed. Install it with: juliaup add $version")

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "TestManifestPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    @test length(discovered.items) == 1

    result = TestHelpers.run_testrun(
        discovered;
        julia_cmd="julia",
        julia_args=["+$version"],
        timeout=1800,
        env=TestHelpers.isolated_depot_env(version)
    )

    passed_events = filter(e -> e.event == :passed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)

    @test length(passed_events) == 1
    @test length(errored_events) == 0
    @test length(failed_events) == 0
end
