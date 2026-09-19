# Where a failure happened, and whether the editor can open it.
#
# These are leaf helpers over a stack trace, needing nothing but Base, so they live in
# their own file and can be included directly by a test without loading the whole test
# server (which the controller test suite has no environment for) — the same arrangement
# as `cpu_target_precompile.jl` and `scratch_env.jl`.

const TESTITEMSERVER_DIR = @__DIR__
const JULIA_BASE_DIR = normpath(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base"))
const JULIA_STDLIB_DIR = Sys.STDLIB

function is_infrastructure_frame(file::AbstractString)
    startswith(file, TESTITEMSERVER_DIR) ||
    startswith(file, JULIA_BASE_DIR) ||
    startswith(file, JULIA_STDLIB_DIR)
end

"""
    resolve_source_file(file) -> Union{Nothing,String}

The absolute path `file` names, or `nothing` when there is no such file on this machine.

A location is only worth reporting if the editor can open what it points at. Two things
produce paths that do not exist: a relative path recorded for a Base file, which
`Base.find_source_file` resolves, and an absolute path baked in when Julia was built, which
nothing can resolve. The second is what a macro expanding to `@test` — `@test_warn` and the
rest of the `Test` stdlib — reports as the source of a failure, and clicking such a failure
in VS Code answers "The editor could not be opened because the file was not found"
(julia-testitems/TestItemRunner.jl#25, JuliaLang/julia#47033).
"""
function resolve_source_file(file)
    path = string(file)
    isempty(path) && return nothing

    if !isabspath(path)
        resolved = Base.find_source_file(path)
        resolved === nothing && return nothing
        path = resolved
    end

    return isfile(path) ? path : nothing
end

function find_error_location(st)
    for frame in st
        frame.from_c && continue
        file = string(frame.file)
        if !isabspath(file)
            resolved = Base.find_source_file(file)
            if resolved !== nothing
                file = resolved
            end
        end
        if !is_infrastructure_frame(file)
            return (file, frame.line)
        end
    end
    # Nothing in the trace is ours. Report the innermost frame instead — unless there is
    # no frame at all. A backtrace can come back empty, and indexing it here threw a
    # `BoundsError` from inside the error-reporting path, which killed the whole test
    # process rather than failing the one item that errored. Both callers already treat a
    # path that is not absolute as "no location", so that is what an empty trace reports.
    isempty(st) && return ("", 0)
    return (string(st[1].file), st[1].line)
end
