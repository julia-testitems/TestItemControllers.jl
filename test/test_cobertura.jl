@testitem "Cobertura export" begin
    using TestItemControllers: write_cobertura
    using TestItemControllers.Results

    empty_result = TestrunResult(TestrunResultDefinitionError[], TestrunResultTestitem[], Dict{String,String}())

    io = IOBuffer()
    @test write_cobertura(io, empty_result) == false
    @test isempty(take!(io))

    covered = TestrunResult(
        TestrunResultDefinitionError[],
        TestrunResultTestitem[],
        Dict{String,String}(),
        [TestrunResultFileCoverage("file:///c%3A/pkg/src/f.jl", Union{Nothing,Int}[nothing, 3, 0, nothing])],
    )

    io = IOBuffer()
    @test write_cobertura(io, covered; root="file:///c%3A/pkg") == true
    xml = String(take!(io))

    @test startswith(xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    @test occursin("<coverage ", xml)
    @test occursin("</coverage>", xml)
    @test occursin("filename=\"src/f.jl\"", xml)
    @test occursin("name=\"f.jl\"", xml)
    @test occursin("<package name=\"src\"", xml)
    # Two instrumentable lines, one of them run.
    @test occursin("lines-valid=\"2\"", xml)
    @test occursin("lines-covered=\"1\"", xml)
    @test occursin("line-rate=\"0.5\"", xml)
    @test occursin("<line number=\"2\" hits=\"3\" branch=\"false\"/>", xml)
    @test occursin("<line number=\"3\" hits=\"0\" branch=\"false\"/>", xml)
    # A line Julia could not instrument has no representation in Cobertura, so it is left
    # out rather than reported as a line nobody ran.
    @test !occursin("number=\"1\"", xml)
    @test !occursin("number=\"4\"", xml)

    # Epoch milliseconds overflow an `Int32`, so on a 32-bit Julia a `round(Int, ...)`
    # here throws an InexactError and no report gets written at all.
    stamp = match(r"timestamp=\"(\d+)\"", xml)
    @test stamp !== nothing
    @test parse(Int64, stamp[1]) > typemax(Int32)
end

@testitem "Cobertura export escapes and skips what it cannot report" begin
    using TestItemControllers: write_cobertura
    using TestItemControllers.Results

    # The consumers parse this with a real XML parser, so an unescaped character in a path
    # is a silently rejected report rather than a visibly broken one.
    result = TestrunResult(
        TestrunResultDefinitionError[],
        TestrunResultTestitem[],
        Dict{String,String}(),
        [
            TestrunResultFileCoverage("file:///c%3A/pkg/src/a%20%26%20b.jl", Union{Nothing,Int}[1, 0]),
            TestrunResultFileCoverage("file:///c%3A/pkg/src/sub/c.jl", Union{Nothing,Int}[nothing]),
            # Not a `file:` URI, so it has no path to report and is skipped.
            TestrunResultFileCoverage("untitled:Untitled-1", Union{Nothing,Int}[1]),
        ],
    )

    io = IOBuffer()
    @test write_cobertura(io, result; root="file:///c%3A/pkg") == true
    xml = String(take!(io))

    @test occursin("filename=\"src/a &amp; b.jl\"", xml)
    @test !occursin("Untitled-1", xml)
    # A directory becomes a dotted package name, the way the format's Java ancestry expects.
    # A file with nothing to instrument is not 0% covered, it is undefined -- reporting it
    # as zero would drag the project's rate down for a file with no code in it.
    @test occursin("<package name=\"src.sub\" line-rate=\"1.0\"", xml)
    # The whole run: one covered line out of two instrumentable ones, the empty file adding
    # nothing to either count.
    @test occursin("lines-valid=\"2\"", xml)
    @test occursin("lines-covered=\"1\"", xml)
end

@testitem "Cobertura export relativizes against a root" begin
    using TestItemControllers: write_cobertura, filepath2uri
    using TestItemControllers.Results

    # Coverage services match the `filename` attributes against paths in the repository.
    # The absolute paths of a CI runner match nothing at all, which is one way a fully
    # covered package gets reported as 0%.
    mktempdir() do dir
        dir = realpath(dir)
        pkg = joinpath(dir, "pkg")
        mkpath(joinpath(pkg, "src"))
        uri = string(filepath2uri(joinpath(pkg, "src", "f.jl")))

        result = TestrunResult(
            TestrunResultDefinitionError[],
            TestrunResultTestitem[],
            Dict{String,String}(),
            [TestrunResultFileCoverage(uri, Union{Nothing,Int}[nothing, 3, 0])],
        )

        io = IOBuffer()
        @test write_cobertura(io, result; root=pkg) == true
        xml = String(take!(io))

        @test occursin("filename=\"src/f.jl\"", xml)
        @test !occursin(replace(pkg, "\\" => "/"), xml)

        # ...and a relative root is resolved against the working directory, which `relpath`
        # does not do on its own.
        io = IOBuffer()
        cd(dir) do
            write_cobertura(io, result; root="pkg")
        end
        @test occursin("filename=\"src/f.jl\"", String(take!(io)))
    end
end

@testitem "Cobertura export writes to a path" begin
    using TestItemControllers: write_cobertura
    using TestItemControllers.Results

    empty_result = TestrunResult(TestrunResultDefinitionError[], TestrunResultTestitem[], Dict{String,String}())

    covered = TestrunResult(
        TestrunResultDefinitionError[],
        TestrunResultTestitem[],
        Dict{String,String}(),
        [TestrunResultFileCoverage("file:///c%3A/pkg/src/f.jl", Union{Nothing,Int}[1])],
    )

    mktempdir() do dir
        path = joinpath(dir, "cobertura.xml")

        # A run without coverage must not leave an empty file behind: an empty report is
        # indistinguishable from a real 0% one to whatever uploads it.
        @test write_cobertura(path, empty_result) == false
        @test !isfile(path)

        @test write_cobertura(path, covered; root="file:///c%3A/pkg") == true
        @test occursin("filename=\"src/f.jl\"", read(path, String))
    end
end
