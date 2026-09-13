# The implementation lives in the test process, which the controller test suite never
# loads. The file only needs Base, so include it directly, as test_scratch_env.jl does
# for scratch_env.jl.
@testmodule CpuTargetImpl begin
    include(joinpath(@__DIR__, "..", "testprocess", "TestItemServer", "src", "cpu_target_precompile.jl"))
end

@testitem "cpu_target_base_variant keeps the CPU name and feature flags" setup=[CpuTargetImpl] begin
    base = CpuTargetImpl.cpu_target_base_variant
    @test base("generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)") == "generic"
    @test base("pentium4") == "pentium4"
    @test base("haswell,-rdrnd") == "haswell,-rdrnd"
    @test base("native") == "native"
    @test base("sandybridge,clone_all") == "sandybridge"
    @test base("skylake,+avx2,opt_size,min_size,base(0)") == "skylake,+avx2"
    @test base("generic; apple-m1,clone_all") == "generic"
    @test base("") == ""
end

@testitem "portable_precompile_applies gates on target, version and image flags" setup=[CpuTargetImpl] begin
    applies = CpuTargetImpl.portable_precompile_applies
    on = (use_compiled_modules=1, use_pkgimages=1)
    portable = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

    @test applies(portable; version=v"1.13.0", opts=on)
    @test applies("pentium4"; version=v"1.10.0", opts=on)
    @test applies("haswell,-rdrnd"; version=v"1.11.9", opts=on)

    @test !applies(nothing; version=v"1.13.0", opts=on)
    @test !applies(""; version=v"1.13.0", opts=on)
    @test !applies("  "; version=v"1.13.0", opts=on)
    @test !applies("native"; version=v"1.13.0", opts=on)
    @test !applies("native,clone_all"; version=v"1.13.0", opts=on)
    # Package images are not checked against the CPU before Julia 1.10.
    @test !applies(portable; version=v"1.9.4", opts=on)
    # Coverage on Julia 1.10 turns package images off: nothing to mismatch.
    @test !applies(portable; version=v"1.10.0", opts=(use_compiled_modules=1, use_pkgimages=0))
    @test !applies(portable; version=v"1.13.0", opts=(use_compiled_modules=0, use_pkgimages=1))
    @test !applies(portable; version=v"1.13.0", opts=(use_compiled_modules=3, use_pkgimages=1))
    # An options object without the field (Julia < 1.9) is never eligible either.
    @test !applies(portable; version=v"1.13.0", opts=(use_compiled_modules=1,))

    # Against this process's real options.
    expected = VERSION >= v"1.10" && Base.JLOptions().use_compiled_modules == 1 &&
        (:use_pkgimages in propertynames(Base.JLOptions()) && Base.JLOptions().use_pkgimages == 1)
    @test applies(portable) == expected
end

@testitem "portable_precompile_cmd and env replicate this process's flags and load path" setup=[CpuTargetImpl] begin
    if VERSION < v"1.9"
        @test_skip "Base.julia_cmd has no cpu_target keyword before Julia 1.9"
    else
        project = Base.active_project()
        cmd = CpuTargetImpl.portable_precompile_cmd("generic", project)
        args = cmd.exec
        i = findfirst(==("-C"), args)
        @test i !== nothing && args[i + 1] == "generic"
        @test "--project=$project" in args
        @test "--startup-file=no" in args
        @test any(a -> startswith(a, "-J"), args)
        @test occursin("Pkg.precompile()", args[end])

        env = CpuTargetImpl.portable_precompile_env()
        sep = Sys.iswindows() ? ';' : ':'
        @test env["JULIA_LOAD_PATH"] == join(Base.load_path(), sep)
        # Everything else is inherited as is.
        @test all(k -> k == "JULIA_LOAD_PATH" || env[k] == ENV[k], keys(env))
    end
end

@testitem "A depot of native images precompiles under a portable JULIA_CPU_TARGET" setup=[TestHelpers, ScratchEnvHelpers] begin
    portable = Sys.ARCH === :x86_64 ? "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)" :
               Sys.ARCH === :aarch64 ? "generic" :
               Sys.ARCH === :i686 ? "pentium4" : nothing
    if VERSION < v"1.10" || portable === nothing
        @test_skip "package-image target checks need Julia 1.10+ and a known architecture"
    else
        # The shape that fails without the fix: the package under test, `Portable`, is
        # stale and depends on `Leaf`, whose image in the depot is fresh but native. The
        # test process accepts `Leaf`'s image, so only `Portable` goes to a worker -- and
        # that worker, on the portable target, refuses `Leaf`. A package without
        # dependencies never gets that far: the worker only loads dependencies.
        work = mktempdir()
        leaf_uuid = "a1b2c3d4-0001-0002-0003-000000000401"
        portable_uuid = "a1b2c3d4-0001-0002-0003-000000000402"
        ScratchEnvHelpers.materialize_package(joinpath(work, "Leaf"); name="Leaf", uuid=leaf_uuid)
        pkg = ScratchEnvHelpers.materialize_package(joinpath(work, "Portable"); name="Portable", uuid=portable_uuid)

        write(joinpath(pkg, "Project.toml"), """
        name = "Portable"
        uuid = "$portable_uuid"
        version = "0.1.0"

        [deps]
        Leaf = "$leaf_uuid"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [compat]
        Test = "1"
        julia = "1"

        [targets]
        test = ["Test"]
        """)
        # Hand-written, so it needs no registry and no `[sources]`; the scratch
        # environment absolutizes the relative path when it mirrors the manifest.
        write(joinpath(pkg, "Manifest.toml"), """
        julia_version = "$(VERSION)"
        manifest_format = "2.0"

        [[deps.Leaf]]
        path = "../Leaf"
        uuid = "$leaf_uuid"
        version = "0.1.0"
        """)
        write(joinpath(pkg, "src", "Portable.jl"), """
        module Portable
        using Leaf
        greet() = "hello from Portable via " * Leaf.greet()
        end
        """)
        write(joinpath(pkg, "test", "tests.jl"), """
        @testitem "Portable loads its dependency" begin
            using Portable
            @test occursin("hello from Leaf", Portable.greet())
        end
        """)

        # A private depot in front of this Julia's defaults (the bundled stdlib images
        # stay visible), fresh for this item so the first run builds native images.
        sep = Sys.iswindows() ? ";" : ":"
        depot_path = string(mktempdir(), sep, join(DEPOT_PATH, sep))

        discovered = TestHelpers.discover_test_items(pkg)
        @test length(discovered.items) == 1

        # Run 1: no CPU target (`nothing` removes an inherited one) -- native images.
        native = TestHelpers.run_testrun(discovered;
            env=Dict{String,Union{String,Nothing}}("JULIA_DEPOT_PATH" => depot_path, "JULIA_CPU_TARGET" => nothing))
        length(ScratchEnvHelpers.passed_ids(native)) == 1 || TestHelpers.dump_run("native run", native; items=discovered.items)
        @test length(ScratchEnvHelpers.passed_ids(native)) == 1

        # Only `Portable` goes stale; `Leaf`'s native image stays, and is what the
        # portable-target worker refuses to load.
        open(joinpath(pkg, "src", "Portable.jl"), "a") do io
            println(io, "# touched so the cache is stale")
        end

        # Run 2: the same depot under the portable target.
        rebuilt = TestHelpers.run_testrun(discovered;
            env=Dict{String,Union{String,Nothing}}("JULIA_DEPOT_PATH" => depot_path, "JULIA_CPU_TARGET" => portable))
        length(ScratchEnvHelpers.passed_ids(rebuilt)) == 1 || TestHelpers.dump_run("portable run", rebuilt; items=discovered.items)
        @test length(ScratchEnvHelpers.passed_ids(rebuilt)) == 1
        @test isempty(ScratchEnvHelpers.error_messages(rebuilt))
        all_output = join(values(rebuilt.outputs))
        @test !occursin("not available with flags", all_output)
        @test !occursin("Failed to precompile", all_output)
        @test occursin("Precompiling the test environment under the portable CPU target", all_output)
    end
end
