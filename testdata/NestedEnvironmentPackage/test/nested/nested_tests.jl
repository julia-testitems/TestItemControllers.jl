@testitem "selected nested dependencies replace canonical test dependencies" begin
    using NestedEnvironmentPackage
    using NestedOnly97

    package_root = realpath(joinpath(@__DIR__, "..", ".."))
    @test realpath(dirname(dirname(pathof(NestedEnvironmentPackage)))) == package_root
    @test NestedEnvironmentPackage.greet() == "hello from the package checkout"
    @test NestedOnly97.origin() == :selected_project
    @test realpath(dirname(dirname(pathof(NestedOnly97)))) == joinpath(package_root, "deps", "NestedOnly97")

    @test realpath(dirname(Base.active_project())) != realpath(@__DIR__)
    @test !occursin("BaseOnly97", read(Base.active_project(), String))
    @test Base.find_package("BaseOnly97") === nothing
    @test all(entry -> !ispath(entry) || realpath(entry) != realpath(@__DIR__), LOAD_PATH)

    @static if VERSION >= v"1.6"
        preferences = Base.get_preferences(Base.UUID("a1b2c3d4-0001-0002-0003-000000000301"))
        @test get(preferences, "flavour", nothing) == "nested"
    end
end

@testitem "a second nested item can use the selected dependency" begin
    using NestedOnly97
    @test NestedOnly97.origin() == :selected_project
end
