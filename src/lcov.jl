"""
LCOV export for the coverage carried on a [`TestrunResult`](@ref).

`CoverageTools` is vendored under `packages/`, which is an implementation detail of this
package — consumers that want an `lcov.info` file should go through here rather than
reaching into the vendored copy and having to know how our URIs map onto file paths.
"""

"""
    write_lcov(io_or_path, result::TestrunResult)

Write the merged coverage of `result` in LCOV info format, the format `genhtml`,
Codecov, Coveralls and friends consume.

Returns `false` and writes nothing when the run collected no coverage — that is the normal
outcome for a run that was not started in coverage mode, not an error.

File URIs are converted back to absolute file paths, since LCOV consumers expect paths.
Entries whose URI is not a `file:` URI are skipped.
"""
function write_lcov(io::IO, result::TestrunResult)
    fcs = _to_coverage_tools(result)
    fcs === nothing && return false
    CoverageTools.LCOV.write(io, fcs)
    return true
end

function write_lcov(path::AbstractString, result::TestrunResult)
    fcs = _to_coverage_tools(result)
    fcs === nothing && return false
    CoverageTools.LCOV.writefile(path, fcs)
    return true
end

function _to_coverage_tools(result::TestrunResult)
    result.coverage === nothing && return nothing
    isempty(result.coverage) && return nothing

    fcs = CoverageTools.FileCoverage[]
    for fc in result.coverage
        filename = try
            uri2filepath(fc.uri)
        catch
            nothing
        end
        filename === nothing && continue
        push!(fcs, CoverageTools.FileCoverage(filename, "", fc.coverage))
    end

    return isempty(fcs) ? nothing : fcs
end
