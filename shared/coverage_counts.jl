# Line hit counts, and the one place they have to be narrowed.
#
# Julia's coverage counters are 64 bit whatever the platform's word size is, and
# `jl_write_coverage_data` writes out what they hold — a line in a hot loop passes
# `typemax(Int32)` easily. The vendored `CoverageTools` stores a count as a `CovCount`,
# which is `Union{Nothing,Int}`, so on a 32 bit run there is nowhere to put such a value:
# reading the file back with `CoverageTools.LCOV.readfile` threw
#
#     OverflowError: overflow parsing "2345022144"
#
# and, because coverage is collected while a test item is running, that error was reported
# as a failure of whatever item happened to be running at the time.
#
# `packages/` holds git subtrees that are never edited by hand, so the file is read here
# instead, and a count is narrowed only where it crosses into one of those vendored
# structures. One that does not fit saturates rather than throwing: knowing a line ran at
# least 2147483647 times is worth more than losing the run over the exact figure.

# Stands in for "not instrumentable" while counts are accumulated, so that the vector can
# stay concretely typed. No real count can reach it.
const _COUNT_ABSENT = typemin(Int64)

"""
    saturating_count(n)

Narrow a 64 bit hit count to what a vendored `CoverageTools.CovCount` can hold. A no-op on a
64 bit platform, where `Int` is already `Int64`.
"""
saturating_count(n::Integer) = Int(clamp(n, typemin(Int), typemax(Int)))
saturating_count(::Nothing) = nothing

"""
    read_lcov_counts(path) -> Vector{CoverageTools.FileCoverage}

Read an LCOV info file into the `FileCoverage` entries the rest of the coverage path expects.

This is `CoverageTools.LCOV.readfile` with the counts accumulated in `Int64` and narrowed by
[`saturating_count`](@ref) on the way into the `CovCount` vector.
"""
function read_lcov_counts(path::AbstractString)
    files = Tuple{String,Vector{Int64}}[]
    counts = nothing

    for line in eachline(path)
        if startswith(line, "end_of_record")
            counts = nothing
        elseif (m = match(r"^SF:(.+)", line)) !== nothing
            counts = Int64[]
            push!(files, (String(m[1]), counts))
        elseif (m = match(r"^DA:(\d+),(-?\d+)(,[^,\s]+)?", line)) !== nothing
            counts === nothing && continue

            ln = parse(Int64, m[1])
            da = parse(Int64, m[2])
            ln > 0 || continue

            if length(counts) < ln
                filled = length(counts)
                resize!(counts, ln)
                fill!(view(counts, (filled + 1):ln), _COUNT_ABSENT)
            end

            counts[ln] = counts[ln] == _COUNT_ABSENT ? da : counts[ln] + da
        end
    end

    return [
        CoverageTools.FileCoverage(
            filename,
            "",
            CoverageTools.CovCount[i == _COUNT_ABSENT ? nothing : saturating_count(i) for i in counts]
        )
        for (filename, counts) in files
    ]
end
