# Environment activation under a portable `JULIA_CPU_TARGET`.
#
# `JULIA_CPU_TARGET` never changes the process it is set in. Julia reads it in exactly
# two places: when it spawns a precompilation worker, which gets the value as `-C`
# (`Base.create_expr_cache`), and when it names a cache file. The process itself keeps
# running on `native`, and judges cache freshness against that.
#
# So a test process handed a portable target -- a CI job restoring a depot built with
# `generic;sandybridge,...;haswell,...`, say -- accepts whatever native images the depot
# already holds, compiles only the stale packages, and hands those to workers that run
# under the portable target and reject the very same native images. Up to Julia 1.12 a
# worker then recompiles every such dependency nested inside itself, which makes every
# activation slow; Julia 1.13 launches its workers with `--compiled-modules=strict`, and
# the rejection is an error ("Precompiled image ... not available with flags ..."):
# activation reports success and every `using` afterwards fails.
#
# The remedy is to precompile from a child started with `-C <base variant>` (`-C generic`
# for the target above). That child rejects native images the way the workers do, so it
# rebuilds them under the portable target, and afterwards the native test process and
# any worker it ever spawns agree on every image in the depot. Only Base is used here, so
# the controller's test suite can include this file directly.

const _MULTIVERSIONING_DIRECTIVES = ("clone_all", "opt_size", "min_size")

"""
    cpu_target_base_variant(target) -> String

The first `;`-separated variant of a `JULIA_CPU_TARGET` string, minus the
multi-versioning directives (`clone_all`, `base(n)`, `opt_size`, `min_size`). The CPU
name and any `+feature`/`-feature` tokens are kept, so the result is a target a plain
`-C` accepts -- `--cpu-target` refuses a multi-versioned string unless a sysimage is
being written.
"""
function cpu_target_base_variant(target::AbstractString)
    first_variant = first(split(target, ';'; limit = 2))
    kept = String[]
    for token in split(first_variant, ',')
        t = strip(token)
        isempty(t) && continue
        t in _MULTIVERSIONING_DIRECTIVES && continue
        startswith(t, "base(") && continue
        push!(kept, String(t))
    end
    return join(kept, ',')
end

"""
    portable_precompile_applies(cpu_target; version=VERSION, opts=Base.JLOptions()) -> Bool

Whether activation has to precompile in a `-C <base>` child rather than in this process.
True only when `cpu_target` (the `JULIA_CPU_TARGET` value, or `nothing`) is non-empty
with a base variant other than `native`, on Julia 1.10 or newer (which is when package
images are checked against the CPU on load -- 1.9 runs them regardless, and there is
nothing to be gained before that), with compiled modules and package images on. Under
`--code-coverage`, Julia 1.10 turns package images off, so there is no target to
mismatch there; 1.11 and later keep them on and are covered.
"""
function portable_precompile_applies(cpu_target::Union{Nothing, AbstractString};
                                     version::VersionNumber = VERSION, opts = Base.JLOptions())
    cpu_target === nothing && return false
    isempty(strip(cpu_target)) && return false
    version >= v"1.10" || return false
    base = cpu_target_base_variant(cpu_target)
    (isempty(base) || base == "native") && return false
    opts.use_compiled_modules == 1 || return false
    # The field only exists from Julia 1.9 on; `opts` may also be a NamedTuple in tests.
    (:use_pkgimages in propertynames(opts) && opts.use_pkgimages == 1) || return false
    return true
end

"""
    portable_precompile_env() -> Dict{String,String}

This process's environment with `JULIA_LOAD_PATH` pinned to the expanded load path,
which is what `Base.create_expr_cache` hands Julia's own precompilation workers. The
expanded form carries the entries that exist only in this process: the active project
and the preferences carrier `activate_env_request` appends to `LOAD_PATH`.
"""
function portable_precompile_env()
    env = Dict{String, String}(ENV)
    env["JULIA_LOAD_PATH"] = join(Base.load_path(), Sys.iswindows() ? ';' : ':')
    return env
end

"""
    portable_precompile_cmd(base, project) -> Cmd

The child command. `Base.julia_cmd(; cpu_target=base)` replicates the flags that go into
Julia's cache flags (`--check-bounds`, `-O`, `-g`, `--inline`, `--pkgimages`,
`--compiled-modules`) and coverage, so the caches the child writes are the ones this
process loads. `--project` is what the child's `Pkg.precompile()` context reads; the load
path comes from the environment. The registry flag mirrors the one `activate_env_request`
sets, so the child cannot start the registry update whose Windows race is described there.
"""
function portable_precompile_cmd(base::AbstractString, project::AbstractString)
    code = "import Pkg; isdefined(Pkg, :UPDATED_REGISTRY_THIS_SESSION) && (Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true); Pkg.precompile()"
    return `$(Base.julia_cmd(; cpu_target = String(base))) --startup-file=no --history-file=no --project=$project -e $code`
end

"""
    run_portable_precompile(base, project; cancelled=() -> false) -> Symbol

Run `Pkg.precompile()` for `project` in a `-C base` child with inherited stdout and
stderr -- in a test process those are the controller's pipe, so the child's output is
process-level activation output exactly like in-process precompilation output. Polls
`cancelled` and kills the child when it fires. Returns `:ok`, `:failed` (non-zero exit,
already warned about) or `:cancelled`.
"""
function run_portable_precompile(base::AbstractString, project::AbstractString; cancelled = () -> false)
    cmd = Cmd(portable_precompile_cmd(base, project); env = portable_precompile_env())
    @info "Precompiling the test environment under the portable CPU target" cpu_target = base
    proc = run(pipeline(ignorestatus(cmd); stdin = devnull); wait = false)
    while process_running(proc)
        if cancelled()
            try
                kill(proc)
            catch
            end
            wait(proc)
            return :cancelled
        end
        sleep(0.2)
    end
    wait(proc)
    if proc.exitcode != 0
        @warn "Precompiling the test environment under the portable CPU target failed; test items will try to load their packages anyway" cpu_target = base exitcode = proc.exitcode
        return :failed
    end
    return :ok
end
