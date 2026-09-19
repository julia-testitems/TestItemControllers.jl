"""
Cobertura XML export for the coverage carried on a [`TestrunResult`](@ref).

The sibling of [`write_lcov`](@ref), for the consumers that take Cobertura rather than
LCOV — GitHub Code Quality's coverage feature takes Cobertura and nothing else.

Cobertura describes branch and method coverage too. Julia's line-count instrumentation
produces neither, and the one consumer this exists for reads line coverage only, so the
branch and complexity attributes are present (the format's consumers expect them) and
always zero.
"""

"""
    write_cobertura(io_or_path, result::TestrunResult; root=nothing)

Write the merged coverage of `result` as a Cobertura XML report.

Returns `false` and writes nothing when the run collected no coverage — that is the normal
outcome for a run that was not started in coverage mode, not an error. The same contract as
[`write_lcov`](@ref), so a caller can drive both from the same `if`.

`root` is a directory path or `file:` URI to relativize the `filename` attributes against;
without it they are absolute. Coverage services match those paths against paths in the
repository, and the absolute paths of a CI runner match nothing at all — which is one way a
fully covered package comes out at 0%. A file outside `root` keeps its absolute path rather
than a `..`-heavy one, the same choice [`write_junit_xml`](@ref) makes.

Paths always use `/` separators, so a Windows leg and a Linux leg of the same matrix
contribute the same file names to a merged report.

Entries whose URI is not a `file:` URI are skipped.
"""
function write_cobertura(io::IO, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    files = _cobertura_files(result, root)
    files === nothing && return false
    _write_cobertura(io, files)
    return true
end

function write_cobertura(path::AbstractString, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    files = _cobertura_files(result, root)
    files === nothing && return false
    open(path, "w") do io
        _write_cobertura(io, files)
    end
    return true
end

# `(filename, lines)` per source file, where `lines` is the `(number, hits)` of every
# instrumentable line. A line Julia could not instrument has no representation in Cobertura
# — there is no "not applicable" hit count — so it is left out rather than reported as a
# line nobody ran.
function _cobertura_files(result::TestrunResult, root::Union{Nothing,AbstractString})
    result.coverage === nothing && return nothing
    isempty(result.coverage) && return nothing

    files = Tuple{String,Vector{Tuple{Int,Int}}}[]
    for fc in result.coverage
        # Shared with the JUnit and LCOV writers: same relativization, same `/` separators,
        # same refusal to walk out of the root with `..`.
        filename = _report_path(fc.uri, root)
        filename === nothing && continue
        lines = Tuple{Int,Int}[]
        for (i, hits) in enumerate(fc.coverage)
            hits === nothing && continue
            push!(lines, (i, hits))
        end
        push!(files, (filename, lines))
    end

    return isempty(files) ? nothing : files
end

# Cobertura's `line-rate` is covered lines over instrumentable lines. A file with nothing to
# instrument is not 0% covered, it is undefined; 1.0 is what every producer emits for it and
# what keeps it from dragging a project's rate down.
function _cobertura_rate(covered::Integer, valid::Integer)
    valid == 0 && return 1.0
    return covered / valid
end

_cobertura_counts(lines) = (count(l -> l[2] > 0, lines), length(lines))

# Cobertura groups classes into packages. Nothing reads the grouping for a language without
# packages, but a report that puts every file in one anonymous bucket is unreadable in the
# viewers that do show it, so the directory is used — dotted, as the format's Java ancestry
# expects.
function _cobertura_package_name(filename::AbstractString)
    dir = dirname(filename)
    isempty(dir) && return "."
    return replace(dir, '/' => '.')
end

function _write_cobertura(io::IO, files::Vector{Tuple{String,Vector{Tuple{Int,Int}}}})
    total_covered = 0
    total_valid = 0
    for (_, lines) in files
        covered, valid = _cobertura_counts(lines)
        total_covered += covered
        total_valid += valid
    end

    # Cobertura timestamps are milliseconds since the epoch.
    timestamp = round(Int, time() * 1000)

    println(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    println(io, "<!DOCTYPE coverage SYSTEM \"http://cobertura.sourceforge.net/xml/coverage-04.dtd\">")
    println(io, "<coverage line-rate=\"", _cobertura_rate(total_covered, total_valid),
        "\" branch-rate=\"0.0\" lines-covered=\"", total_covered,
        "\" lines-valid=\"", total_valid,
        "\" branches-covered=\"0\" branches-valid=\"0\" complexity=\"0\" version=\"2.0.3\" timestamp=\"",
        timestamp, "\">")
    # The filenames are already relative to the root the caller gave us, so the source root
    # a consumer should join them against is wherever it checked the repository out.
    println(io, "  <sources>")
    println(io, "    <source>.</source>")
    println(io, "  </sources>")
    println(io, "  <packages>")

    for (package, members) in _group_by_package(files)
        pkg_covered = 0
        pkg_valid = 0
        for (_, lines) in members
            covered, valid = _cobertura_counts(lines)
            pkg_covered += covered
            pkg_valid += valid
        end
        println(io, "    <package name=\"", _xml_escape(package), "\" line-rate=\"",
            _cobertura_rate(pkg_covered, pkg_valid), "\" branch-rate=\"0.0\" complexity=\"0\">")
        println(io, "      <classes>")
        for (filename, lines) in members
            covered, valid = _cobertura_counts(lines)
            println(io, "        <class name=\"", _xml_escape(basename(filename)),
                "\" filename=\"", _xml_escape(filename), "\" line-rate=\"",
                _cobertura_rate(covered, valid), "\" branch-rate=\"0.0\" complexity=\"0\">")
            println(io, "          <methods/>")
            println(io, "          <lines>")
            for (number, hits) in lines
                println(io, "            <line number=\"", number, "\" hits=\"", hits, "\" branch=\"false\"/>")
            end
            println(io, "          </lines>")
            println(io, "        </class>")
        end
        println(io, "      </classes>")
        println(io, "    </package>")
    end

    println(io, "  </packages>")
    println(io, "</coverage>")

    return nothing
end

# Package order follows first appearance, and files keep the order the result gave them, so
# the same run always produces the same bytes.
function _group_by_package(files::Vector{Tuple{String,Vector{Tuple{Int,Int}}}})
    order = String[]
    groups = Dict{String,Vector{Tuple{String,Vector{Tuple{Int,Int}}}}}()
    for entry in files
        package = _cobertura_package_name(entry[1])
        members = get!(groups, package) do
            push!(order, package)
            Tuple{String,Vector{Tuple{Int,Int}}}[]
        end
        push!(members, entry)
    end
    return [(package, groups[package]) for package in order]
end
