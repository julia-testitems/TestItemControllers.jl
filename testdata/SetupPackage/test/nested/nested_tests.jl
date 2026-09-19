# These items live one directory below the `@testmodule` they use — `ConfigSetup` is
# defined in `../setup_tests.jl` — which is the arrangement that exposes a test item being
# run with the setup's file path instead of its own.

@testitem "nested item resolves its own dir" setup=[ConfigSetup] begin
    # `@__DIR__` rather than a bare relative path: the test process `cd`s to the item's own
    # directory before the setups are evaluated, so a relative path resolves correctly even
    # when the path handed to `include_string` is wrong.
    @test basename(@__DIR__) == "nested"
    @test basename(@__FILE__) == "nested_tests.jl"
    @test isfile(joinpath(@__DIR__, "fixture.txt"))

    # The setup is genuinely used, so it cannot be optimized away as unnecessary.
    @test ConfigSetup.CONFIG["multiplier"] == 10
end

@testitem "nested item fails in its own file" setup=[ConfigSetup] begin
    @test ConfigSetup.CONFIG["multiplier"] == 10
    @test false
end
