# In-process hang diagnostics.
#
# The controller sends a `timeoutMs` deadline with every test item. We arm a watchdog just
# short of it, so that an item which is about to be killed for running too long leaves a
# stack behind instead of a single "timed out" line. Three constraints shape this:
#
#   * The watchdog must not depend on libuv. When a test item wedges the main thread no
#     thread services the event loop any more, so `sleep`, `Timer` and socket writes never
#     complete. The watchdog therefore paces itself with `Libc.systemsleep` (a plain OS
#     sleep) and writes to a file through `IOStream`, which is a blocking `write(2)` and
#     needs no running loop.
#   * The watchdog must not share a thread with the test item. The launch reserves two
#     interactive threads on Julia >= 1.9 (see `src/testprocess.jl`): the main task — and
#     therefore the runner loop and every test item — sits on the first, and this watchdog
#     runs on the second.
#   * It cannot help against an item that neither allocates nor yields. Such an item never
#     reaches a GC safepoint, so the watchdog's first allocation blocks behind a GC that
#     can never start. The controller's own timeout remains the backstop for that case.
#
# The dump goes to a file of its own rather than to stderr: a `Profile.print` is far larger
# than the 4 KiB POSIX pipes guarantee to write atomically (and Windows named pipes
# guarantee nothing), so sharing the captured-output stream with a test item that is still
# printing would shred both. One writer, one file, no framing needed. The controller reads
# the file when its own timeout fires and attributes the contents to whichever item the
# process was running.

# Set by the controller on the test process launch; absent means diagnostics are disabled.
const DIAGNOSTICS_FILE_ENV_VAR = "JULIA_TESTITEMSERVER_DIAGNOSTICS_FILE"

# Fire this far ahead of the controller's deadline. The real margin comes from the grace
# period the controller adds before it kills the process; this only avoids racing it.
const WATCHDOG_LEAD_MS = 250.0

# Granularity of the watchdog's own sleep, and how long we let the sampler run.
const WATCHDOG_POLL_SECONDS = 0.05
const WATCHDOG_PROFILE_SECONDS = 1.0

const WATCHDOG_FILE = Ref{Union{Nothing,String}}(nothing)
const WATCHDOG_PROFILE = Ref{Union{Nothing,Module}}(nothing)
# `time()` at which to dump, or 0.0 when disarmed. Written by the runner loop, read by the
# watchdog thread; a torn read would at worst dump early or late.
const WATCHDOG_DEADLINE = Ref{Float64}(0.0)
const WATCHDOG_ITEM_ID = Ref{String}("")
const WATCHDOG_ITEM_TIMEOUT_MS = Ref{Float64}(0.0)
const WATCHDOG_RUNNING = Ref{Bool}(false)

function _init_watchdog_globals!()
    WATCHDOG_FILE[] = nothing
    WATCHDOG_PROFILE[] = nothing
    WATCHDOG_DEADLINE[] = 0.0
    WATCHDOG_ITEM_ID[] = ""
    WATCHDOG_ITEM_TIMEOUT_MS[] = 0.0
    WATCHDOG_RUNNING[] = false
    return nothing
end

# `Profile` is a stdlib, but the test process runs in a pinned environment
# (`testprocess/environments/v*`) whose manifest does not list it, so `import Profile` in
# this package would not resolve. Loading it by name against the load path stack does —
# `@stdlib` is still on it at startup, before any test environment is activated. If that
# ever stops being true we degrade to a text-only dump instead of failing.
function _load_profile_module()
    return try
        Base.require(Main, :Profile)
    catch err
        @debug "Profile is not loadable in this test process; hang diagnostics will be text only" exception=err
        nothing
    end
end

function _write_diagnostics(text::AbstractString)
    file = WATCHDOG_FILE[]
    file === nothing && return nothing
    try
        open(file, "a") do io
            write(io, text)
            flush(io)
        end
    catch err
        # There is nothing to fall back to: this path exists precisely because the normal
        # channels may be unusable.
    end
    return nothing
end

function _capture_profile(prof::Module)
    prof.init(n = 10^7, delay = 0.005)
    prof.clear()
    prof.start_timer()
    try
        t0 = time()
        while time() - t0 < WATCHDOG_PROFILE_SECONDS
            Libc.systemsleep(WATCHDOG_POLL_SECONDS)
        end
    finally
        prof.stop_timer()
    end

    io = IOContext(IOBuffer(), :displaysize => (24, 200))
    # `groupby` only exists from Julia 1.8 on, and `print` warns about empty groups and
    # about Windows sampling only the main thread — neither belongs in a test item's output.
    Logging.with_logger(Logging.NullLogger()) do
        try
            prof.print(io; groupby = :thread, C = false, maxdepth = 40)
        catch err
            prof.print(io; C = false, maxdepth = 40)
        end
    end
    return String(take!(io.io))
end

function _memory_summary()
    return try
        free = Sys.free_memory() / 2^30
        total = Sys.total_memory() / 2^30
        live = Base.gc_live_bytes() / 2^30
        string(round(live, digits = 2), " GiB live, ", round(free, digits = 2), " of ",
            round(total, digits = 2), " GiB system memory free")
    catch err
        "unavailable"
    end
end

function _thread_summary()
    return @static if VERSION >= v"1.9"
        string(Threads.nthreads(:default), " default + ", Threads.nthreads(:interactive), " interactive")
    else
        string(Threads.nthreads())
    end
end

function _build_dump(testitem_id::AbstractString, timeout_ms::Float64)
    io = IOBuffer()
    rule = "─"^78
    println(io)
    println(io, rule)
    println(io, "Hang diagnostics for test item '", testitem_id, "'")
    println(io, "Captured by the test process watchdog because the item was still running ",
        round(timeout_ms / 1000, digits = 1), "s into its timeout.")
    println(io, "Julia ", VERSION, " on ", Sys.MACHINE, ", pid ", getpid(), ", threads: ", _thread_summary())
    println(io, "Memory: ", _memory_summary())
    println(io, rule)

    prof = WATCHDOG_PROFILE[]
    if prof === nothing
        println(io, "No CPU profile: the Profile stdlib is not loadable in this test process.")
    else
        try
            profile_text = _capture_profile(prof)
            if isempty(strip(profile_text))
                println(io, "No CPU profile: the sampler collected no snapshots.")
            else
                print(io, profile_text)
            end
        catch err
            println(io, "No CPU profile: capturing one failed with ", sprint(showerror, err))
        end
    end
    println(io, rule)
    return String(take!(io))
end

function _watchdog_loop()
    while true
        Libc.systemsleep(WATCHDOG_POLL_SECONDS)

        deadline = WATCHDOG_DEADLINE[]
        (deadline > 0.0 && time() >= deadline) || continue

        # Disarm before dumping: one dump per armed item, however long the dump takes.
        WATCHDOG_DEADLINE[] = 0.0
        testitem_id = WATCHDOG_ITEM_ID[]
        timeout_ms = WATCHDOG_ITEM_TIMEOUT_MS[]

        try
            _write_diagnostics(_build_dump(testitem_id, timeout_ms))
        catch err
            # Deliberately swallowed — a failing watchdog must not take the process down.
        end
    end
end

"""
    start_watchdog!()

Load the diagnostics file path and the `Profile` module and start the watchdog thread.
Returns `true` when the watchdog is running. Called once, at test process startup, while
the process is still healthy.
"""
function start_watchdog!()
    _init_watchdog_globals!()

    file = get(ENV, DIAGNOSTICS_FILE_ENV_VAR, "")
    isempty(file) && return false
    WATCHDOG_FILE[] = file
    WATCHDOG_PROFILE[] = _load_profile_module()

    @static if VERSION >= v"1.9"
        # Preferred: our own interactive thread, which the default pool cannot starve.
        if Threads.nthreads(:interactive) >= 2
            Threads.@spawn :interactive _watchdog_loop()
            WATCHDOG_RUNNING[] = true
            return true
        end
    end

    @static if VERSION >= v"1.3"
        # Fallback: any spare thread. Weaker, because a test item that saturates the
        # default pool can keep the watchdog off the CPU.
        if Threads.nthreads() >= 2
            Threads.@spawn _watchdog_loop()
            WATCHDOG_RUNNING[] = true
            return true
        end
    end

    @debug "No spare thread for the hang watchdog; timeouts will not produce a diagnostic dump"
    return false
end

"""
    arm_watchdog!(testitem_id, timeout_ms)

Schedule a diagnostic dump shortly before `timeout_ms` from now. A `missing` timeout — the
controller did not set one for this item — disarms instead.
"""
function arm_watchdog!(testitem_id::AbstractString, timeout_ms::Union{Missing,Float64})
    if !WATCHDOG_RUNNING[] || timeout_ms === missing || timeout_ms <= 0
        WATCHDOG_DEADLINE[] = 0.0
        return nothing
    end

    WATCHDOG_ITEM_ID[] = String(testitem_id)
    WATCHDOG_ITEM_TIMEOUT_MS[] = timeout_ms
    WATCHDOG_DEADLINE[] = time() + max(0.0, timeout_ms - WATCHDOG_LEAD_MS) / 1000
    return nothing
end

"""
    disarm_watchdog!()

Cancel any pending dump. Cheap enough to call unconditionally after every test item.
"""
function disarm_watchdog!()
    WATCHDOG_DEADLINE[] = 0.0
    return nothing
end
