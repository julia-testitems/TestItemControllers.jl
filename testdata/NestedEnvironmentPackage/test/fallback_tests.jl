@testitem "an in-package active fallback is the selected environment" begin
    using NestedEnvironmentPackage
    using NestedOnly97

    selected_project = realpath(joinpath(@__DIR__, "nested"))
    @test NestedEnvironmentPackage.greet() == "hello from the package checkout"
    @test NestedOnly97.origin() == :selected_project
    @test !occursin("BaseOnly97", read(Base.active_project(), String))
    @test Base.find_package("BaseOnly97") === nothing
    @test all(entry -> !ispath(entry) || realpath(entry) != selected_project, LOAD_PATH)
end
