# Probes for the module teardown that frees whatever a test item bound to a global.
#
# Every test item runs in a module of its own, and Julia cannot unload a module, so
# without the teardown the arrays below stay reachable for the life of the test process
# (julia-testitems/TestItemRunner.jl#65).
#
# One probe per binding form the teardown has to deal with: a plain global and a type
# annotated one, both of which have to be released, and a `const`, which cannot be from
# Julia 1.12 on. If Julia ever makes that last one collectable this fixture fails, which
# is the reminder to update the docstring of `release_module_globals!` and the user docs.
#
# The two items have to run in this order on the same test process, which is why the test
# drives them as two consecutive test runs rather than as one run of two items: the
# controller keeps its remaining work in a `Dict`, so the order within a single run is not
# something a test can rely on.
#
# The probes live in `Main` rather than in the item's own module precisely because `Main`
# is what the teardown does *not* touch.

@testitem "memory probe: bind" begin
    leaked = zeros(UInt8, 8_000_000)
    Core.eval(Main, :(MEMORY_PROBE = $(WeakRef(leaked))))
    @test length(leaked) == 8_000_000

    typed::Vector{UInt8} = zeros(UInt8, 8_000_000)
    Core.eval(Main, :(MEMORY_PROBE_TYPED = $(WeakRef(typed))))
    @test length(typed) == 8_000_000

    const pinned = zeros(UInt8, 8_000_000)
    Core.eval(Main, :(MEMORY_PROBE_CONST = $(WeakRef(pinned))))
    @test length(pinned) == 8_000_000
end

@testitem "memory probe: check" begin
    GC.gc(true)
    GC.gc(true)

    @test isdefined(Main, :MEMORY_PROBE)
    @test Main.MEMORY_PROBE.value === nothing

    # Released through the empty-array fallback, because `nothing` does not fit the
    # declared type
    @test Main.MEMORY_PROBE_TYPED.value === nothing

    # Not released, and cannot be — see the note above
    @test Main.MEMORY_PROBE_CONST.value !== nothing
end
