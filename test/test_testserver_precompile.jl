@testitem "The test process environment precompiles cleanly" begin
    # `TestItemServer` assembles the vendored packages by hand, and an override that
    # *redefines* one of their methods rather than adding a more specific one is a method
    # overwrite — which Julia rejects outright while a package precompiles.
    #
    # Nothing else in this suite notices directly: precompilation is warn-only on the path a
    # test process takes, so the package still loads. What it costs is a full source reload
    # of the vendored stack in every test process (tens of seconds each) and a precompile
    # banner on its stderr, which then lands in whatever a test item captures. Those
    # second-order effects are how it last surfaced, in assertions about process output.
    # Assert the cache is actually built instead.
    env_dir = normpath(joinpath(@__DIR__, "..", "testprocess", "environments"))
    versioned = joinpath(env_dir, "v$(VERSION.major).$(VERSION.minor)")
    project = isdir(versioned) ? versioned : joinpath(env_dir, "fallback")

    # `Base.compilecache` rather than `Pkg.precompile`: it rebuilds unconditionally, so a
    # cache some other test item already wrote cannot short-circuit the check, and it reports
    # a failure as a `Core.PrecompilableError` return value — `Pkg.precompile` reports one as
    # a `?` in its progress list and still exits 0.
    code = """
        result = Base.compilecache(Base.identify_package("TestItemServer"))
        result isa Tuple || exit(1)
        """
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia --startup-file=no --history-file=no --project=$project -e $code`

    io = IOBuffer()
    process = run(pipeline(ignorestatus(cmd), stdout=io, stderr=io))
    output = String(take!(io))

    ok = success(process) &&
        !occursin("Method overwriting is not permitted", output) &&
        !occursin("overwritten at", output)
    if !ok
        println("── precompiling TestItemServer in $project ──")
        println(output)
    end

    @test success(process)
    @test !occursin("Method overwriting is not permitted", output)
    @test !occursin("overwritten at", output)
end
