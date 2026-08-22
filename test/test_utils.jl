@testitem "makechunks basic" begin
    using TestItemControllers: makechunks

    chunks = makechunks([1, 2, 3, 4, 5, 6], 3)
    @test length(chunks) == 3
    @test vcat(chunks...) == [1, 2, 3, 4, 5, 6]
end

@testitem "makechunks single chunk" begin
    using TestItemControllers: makechunks

    chunks = makechunks([1, 2, 3], 1)
    @test length(chunks) == 1
    @test chunks[1] == [1, 2, 3]
end

@testitem "makechunks more chunks than elements" begin
    using TestItemControllers: makechunks

    chunks = makechunks([1, 2], 3)
    @test length(chunks) == 3
    # All elements should still be present
    @test sort(vcat(chunks...)) == [1, 2]
end

@testitem "makechunks uneven split" begin
    using TestItemControllers: makechunks

    chunks = makechunks([1, 2, 3, 4, 5], 2)
    @test length(chunks) == 2
    @test vcat(chunks...) == [1, 2, 3, 4, 5]
end

@testitem "makechunks error on n < 1" begin
    using TestItemControllers: makechunks

    @test_throws ErrorException makechunks([1, 2, 3], 0)
    @test_throws ErrorException makechunks([1, 2, 3], -1)
end

@testitem "exit info string" begin
    using TestItemControllers: _exit_info_string

    # A process that exited with a code has `termsignal == 0`; that is not a signal.
    @test _exit_info_string(1, 0) == "exit code 1"
    @test _exit_info_string(66, nothing) == "exit code 66"
    @test _exit_info_string(-1073741819, 0) == "exit code -1073741819 (0xC0000005)"
    @test _exit_info_string(nothing, 11) == "SIGSEGV (signal 11)"
    @test _exit_info_string(nothing, 40) == "signal 40 (signal 40)"
    @test _exit_info_string(nothing, 0) === nothing
    @test _exit_info_string(nothing, nothing) === nothing
end

@testitem "_truncate_for_log strips ANSI escapes" begin
    using TestItemControllers: _truncate_for_log

    # Test processes run with `--color=yes`, so anything we fold into our own log records
    # arrives coloured; the controller log is a plain output channel that renders none of it.
    @test _truncate_for_log("\e[31mred\e[0m") == "red"
    @test _truncate_for_log("\e[1;32mbold green\e[0m — καλά 🎉") == "bold green — καλά 🎉"
    @test _truncate_for_log("\e]0;a title\acleared\e[2K") == "cleared"
    @test _truncate_for_log("plain text") == "plain text"
end

@testitem "_truncate_for_log truncates on a character boundary" begin
    using TestItemControllers: _truncate_for_log

    s = repeat("α", 100)  # 200 bytes
    r = _truncate_for_log(s; max_bytes=51)
    @test isvalid(r)
    @test startswith(r, repeat("α", 25))
    @test occursin("bytes truncated", r)

    # Escapes are removed before the budget applies, so they cannot eat into it or be
    # severed part way through.
    @test _truncate_for_log("\e[31m" * repeat("a", 10) * "\e[0m"; max_bytes=20) ==
        repeat("a", 10)
end
