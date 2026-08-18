@testitem "add works" begin
    using TestManifestPackage
    @test add(1, 2) == 3
end
