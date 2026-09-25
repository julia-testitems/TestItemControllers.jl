# Resident memory of the current process, for the `memoryThreshold` recycle check.
#
# Base has `Sys.maxrss()`, but that is the *peak* resident size, which never goes down, so
# a process that once touched a lot of memory would be recycled after every item from then
# on. This asks the OS for the current figure instead. The test server runs on every Julia
# version from 1.0 on, so this sticks to plain `ccall` and Base APIs that 1.0 has. Only
# Base is used, so the controller's test suite can include this file directly.

# `struct mach_task_basic_info` from <mach/task_info.h>. The header wraps it in
# `#pragma pack(push, 4)`, but every field already sits at an offset that is a multiple
# of its size, so the layout is the same as Julia's: 48 bytes, `resident_size` at 8.
struct _MachTimeValue
    seconds::Int32
    microseconds::Int32
end

struct _MachTaskBasicInfo
    virtual_size::UInt64
    resident_size::UInt64
    resident_size_max::UInt64
    user_time::_MachTimeValue
    system_time::_MachTimeValue
    policy::Int32
    suspend_count::Int32
end

const _MACH_TASK_BASIC_INFO = UInt32(20)
# `MACH_TASK_BASIC_INFO_COUNT`: the struct's size in `natural_t` (32-bit) units, i.e. 12.
const _MACH_TASK_BASIC_INFO_COUNT = UInt32(div(sizeof(_MachTaskBasicInfo), sizeof(UInt32)))

# `PROCESS_MEMORY_COUNTERS` from <psapi.h>. `SIZE_T` is `Csize_t`, so this is also right
# in a 32-bit Julia.
struct _ProcessMemoryCounters
    cb::UInt32
    PageFaultCount::UInt32
    PeakWorkingSetSize::Csize_t
    WorkingSetSize::Csize_t
    QuotaPeakPagedPoolUsage::Csize_t
    QuotaPagedPoolUsage::Csize_t
    QuotaPeakNonPagedPoolUsage::Csize_t
    QuotaNonPagedPoolUsage::Csize_t
    PagefileUsage::Csize_t
    PeakPagefileUsage::Csize_t
end

"""
    _current_rss() -> Union{Int,Nothing}

The current resident set size of this process in bytes (the working set on Windows), or
`nothing` when it cannot be determined on this platform.
"""
function _current_rss()
    try
        if Sys.islinux()
            # Second field of /proc/self/statm: resident pages.
            fields = split(read("/proc/self/statm", String))
            pages = parse(Int, fields[2])
            return pages * Int(ccall(:getpagesize, Cint, ()))
        elseif Sys.isapple()
            # `mach_task_self()` is a macro for the global `mach_task_self_`.
            task = unsafe_load(cglobal(:mach_task_self_, UInt32))
            info = Ref(_MachTaskBasicInfo(0, 0, 0, _MachTimeValue(0, 0), _MachTimeValue(0, 0), 0, 0))
            count = Ref(_MACH_TASK_BASIC_INFO_COUNT)
            kr = ccall(:task_info, Cint,
                (UInt32, UInt32, Ptr{_MachTaskBasicInfo}, Ptr{UInt32}),
                task, _MACH_TASK_BASIC_INFO, info, count)
            kr == 0 || return nothing
            return Int(info[].resident_size)
        elseif Sys.iswindows()
            z = Csize_t(0)
            counters = Ref(_ProcessMemoryCounters(UInt32(sizeof(_ProcessMemoryCounters)), 0, z, z, z, z, z, z, z, z))
            handle = ccall((:GetCurrentProcess, "kernel32"), stdcall, Ptr{Cvoid}, ())
            ok = ccall((:K32GetProcessMemoryInfo, "kernel32"), stdcall, Cint,
                (Ptr{Cvoid}, Ptr{_ProcessMemoryCounters}, UInt32),
                handle, counters, UInt32(sizeof(_ProcessMemoryCounters)))
            ok == 0 && return nothing
            return Int(counters[].WorkingSetSize)
        else
            return nothing
        end
    catch
        return nothing
    end
end
