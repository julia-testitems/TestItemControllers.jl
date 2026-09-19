# The implementation lives in the test process, which the controller test suite never
# loads. The file only needs Base, so include it directly, as test_cpu_target.jl does for
# cpu_target_precompile.jl.
@testmodule ErrorLocationImpl begin
    include(joinpath(@__DIR__, "..", "testprocess", "TestItemServer", "src", "error_location.jl"))
end

@testitem "find_error_location survives an empty stack trace" setup=[ErrorLocationImpl] begin
    # `catch_backtrace()` can produce a trace with no Julia frames left in it, and
    # `find_error_location` then indexed frame 1 of an empty vector. That `BoundsError`
    # was thrown from inside the error-reporting path, so it did not fail the test item
    # that errored -- it took the whole test process down with
    # "BoundsError: attempt to access 0-element Vector{Base.StackTraces.StackFrame} at
    # index [1]".
    file, line = ErrorLocationImpl.find_error_location(Base.StackTraces.StackFrame[])

    # Both callers build a location with `isabspath(file) ? filepath2uri(file) : ""` and
    # `Position(max(1, line), 1)`, so this pair means "no location" to them.
    @test file == ""
    @test !isabspath(file)
    @test line == 0
    @test max(1, line) == 1
end

@testitem "find_error_location prefers the first frame outside the infrastructure" setup=[ErrorLocationImpl] begin
    frame(file, line; from_c=false) =
        Base.StackTraces.StackFrame(:f, Symbol(file), line, nothing, from_c, false, UInt64(0))

    # Any absolute path outside the server, Base and the stdlib counts as the user's.
    user_file = @__FILE__
    server_file = joinpath(ErrorLocationImpl.TESTITEMSERVER_DIR, "TestItemServer.jl")

    st = [frame(server_file, 10), frame(user_file, 42)]
    @test ErrorLocationImpl.find_error_location(st) == (user_file, 42)

    # C frames are skipped wherever they sit.
    st = [frame(user_file, 7; from_c=true), frame(user_file, 42)]
    @test ErrorLocationImpl.find_error_location(st) == (user_file, 42)
end

@testitem "find_error_location falls back to the innermost frame when all are infrastructure" setup=[ErrorLocationImpl] begin
    frame(file, line) = Base.StackTraces.StackFrame(:f, Symbol(file), line, nothing, false, false, UInt64(0))

    server_file = joinpath(ErrorLocationImpl.TESTITEMSERVER_DIR, "TestItemServer.jl")
    st = [frame(server_file, 10), frame(server_file, 20)]

    # Nothing here belongs to the user, so the innermost frame is the best answer there is.
    @test ErrorLocationImpl.find_error_location(st) == (server_file, 10)
end
