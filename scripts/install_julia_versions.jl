using Pkg

for minor in 0:13
    version = "1.$minor"
    println("Installing Julia $version...")
    run(ignorestatus(`juliaup add $version`))
end

# Every version installed above shares this depot, and Julia 1.7's bundled 7z cannot
# decompress zstd — 7z only learned that in v17.6. Pkg asks the package server for a zstd
# compressed registry from Julia 1.13 on, everywhere except Windows, where it skips zstd
# for exactly this reason (`Pkg/src/PlatformEngines.jl`). That carve-out is by platform
# rather than by what else lives in the depot, so on Linux and macOS a `General.tar.zst`
# lands here and `check_julia_version("1.7")` fails on it, while the same test passes on
# Windows. An unpacked registry is a plain folder that every version reads.
#
# Only where the problem exists, though: on Windows the registry is already gzip, and an
# unpacked one there makes Pkg's replace-on-write dance leave `*.pid.deleted` entries that
# the concurrent test processes then trip over with `stat: permission denied`.
if !Sys.iswindows()
    registries = joinpath(first(DEPOT_PATH), "registries")
    packed = isdir(registries) && any(i -> startswith(i, "General.tar"), readdir(registries))

    if packed || !isdir(joinpath(registries, "General"))
        println("Installing the General registry unpacked, so that Julia 1.7 can read it...")

        # Removing the packed registry has to happen outside the `withenv` below: with
        # `JULIA_PKG_UNPACK_REGISTRY` set, Pkg looks for unpacked registries only and
        # reports the packed one it is standing on as not installed.
        packed && Pkg.Registry.rm("General")

        withenv("JULIA_PKG_UNPACK_REGISTRY" => "true") do
            Pkg.Registry.add("General")
        end
    end

    # Converting what is here now is not enough: anything later in this job that installs
    # or refreshes the registry — the run itself, or a test process resolving an
    # environment — would put a packed one back. Setting the variable for the rest of the
    # job keeps every such download unpacked too.
    github_env = get(ENV, "GITHUB_ENV", nothing)

    if github_env !== nothing
        open(github_env, "a") do io
            println(io, "JULIA_PKG_UNPACK_REGISTRY=true")
        end
    end
end
