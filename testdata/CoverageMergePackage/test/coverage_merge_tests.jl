@testitem "calls first_item_only" begin
    using CoverageMergePackage
    @test first_item_only(1) == 2
end

@testitem "calls second_item_only" begin
    using CoverageMergePackage
    @test second_item_only(1) == 2
end
