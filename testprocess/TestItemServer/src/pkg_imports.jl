include("../../../packages/TestEnv/src/TestEnv.jl")
include("../../../packages/URIParser/src/URIParser.jl")
include("../../../packages/JSON/src/JSON.jl")

if VERSION >= v"1.10.0"
    include("../../../packages/Preferences/src/Preferences.jl")
end

if VERSION >= v"1.6.0"
    include("../../../packages/OrderedCollections/src/OrderedCollections.jl")
else
    include("../../../packages-old/v1.5/OrderedCollections/src/OrderedCollections.jl")
end
@static if VERSION >= v"1.10.0"
    include("../../../packages/CodeTracking/src/CodeTracking.jl")
elseif VERSION >= v"1.6.0"
        include("../../../packages-old/v1.9/CodeTracking/src/CodeTracking.jl")
    else
        include("../../../packages-old/v1.5/CodeTracking/src/CodeTracking.jl")
    end
include("../../../packages/CoverageTools/src/CoverageTools.jl")
include("../../../packages/CancellationTokens/src/CancellationTokens.jl")

module JSONRPC
import ..CancellationTokens
import ..JSON
import UUIDs
import Sockets
include("../../../packages/JSONRPC/src/packagedef.jl")
end

module JuliaInterpreter
    using ..CodeTracking

    @static if VERSION >= v"1.10.0"
        include("../../../packages/JuliaInterpreter/src/packagedef.jl")
    elseif VERSION >= v"1.6.0"
        include("../../../packages-old/v1.9/JuliaInterpreter/src/packagedef.jl")
    else
        include("../../../packages-old/v1.5/JuliaInterpreter/src/packagedef.jl")
    end
end

@static if VERSION >= v"1.10.0"
    include("../../../packages/Compiler/src/Compiler.jl")
end

module LoweredCodeUtils
    @static if VERSION >= v"1.10.0"
        using ..CodeTracking: MethodInfoKey

        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame, Interpreter, RecursiveInterpreter
        using ..JuliaInterpreter: codelocation, is_global_ref, is_global_ref_egal, is_quotenode_egal, is_return,
                        lookup, lookup_return, linetable, moduleof, next_until!, nstatements, pc_expr,
                        step_expr!, whichtt, extract_method_table
        import ..Compiler
        const CC = Compiler

        include("../../../packages/LoweredCodeUtils/src/packagedef.jl")
    elseif VERSION >= v"1.6.0"
        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame
        using ..JuliaInterpreter: @lookup, moduleof, pc_expr, step_expr!, is_global_ref, is_quotenode_egal, whichtt,
            next_until!, finish_and_return!, get_return, nstatements, codelocation, linetable,
            is_return, lookup_return

        include("../../../packages-old/v1.9/LoweredCodeUtils/src/packagedef.jl")
    else
        using ..JuliaInterpreter
        using ..JuliaInterpreter: SSAValue, SlotNumber, Frame
        using ..JuliaInterpreter: @lookup, moduleof, pc_expr, step_expr!, is_global_ref, is_quotenode, whichtt,
            next_until!, finish_and_return!, get_return, nstatements, codelocation, linetable,
            is_return, lookup_return, is_GotoIfNot, is_ReturnNode

        include("../../../packages-old/v1.5/LoweredCodeUtils/src/packagedef.jl")
    end
end

module Revise
    @static if VERSION >= v"1.10.0"
        using TOML
        using ..OrderedCollections, ..CodeTracking, ..JuliaInterpreter, ..LoweredCodeUtils, ..Preferences

        using ...CodeTracking: PkgFiles, basedir, srcfiles, basepath, MethodInfoKey
        using ...JuliaInterpreter: Compiled, Frame, Interpreter, LineTypes, RecursiveInterpreter
        using ...JuliaInterpreter: codelocs, finish_and_return!, get_return, is_doc_expr, isassign,
                        isidentical, is_quotenode_egal, linetable, lookup, moduleof,
                        pc_expr, scopeof, step_expr!
        using ...LoweredCodeUtils: next_or_nothing!, callee_matches

        include("../../../packages/Revise/src/packagedef.jl")

        # Revise seeds the cache source hash with a `UInt64`, while the seed `hash` takes is a
        # `UInt` — 32 bits wide on a 32 bit platform. Its package callback dies there with
        # `MethodError: no method matching hash(::UInt64, ::UInt64)`, and every test item that
        # loads a package in that process reports the failed callback as its own error.
        #
        # `packages/` holds git subtrees that are never edited by hand, so the method is added
        # here instead, where this module is assembled. It is deliberately *more specific* than
        # the vendored `cache_src_id(inc)` rather than a redefinition of it: redefining is
        # method overwriting, which Julia rejects outright while this package precompiles. Both
        # call sites pass a `Base.CacheHeaderIncludes`, so this one wins dispatch. `inc.hash` is
        # a `UInt32`, so widening it to `UInt` is exact. Guarded like the definition it shadows
        # (https://github.com/JuliaLang/julia/pull/49866); older versions hash `inc.mtime` and
        # are unaffected. Drop this once the fix is in a released Revise.
        @static if Sys.WORD_SIZE == 32 && VERSION >= v"1.11.0-DEV.683" &&
                   isdefined(Base, :CacheHeaderIncludes)
            cache_src_id(inc::Base.CacheHeaderIncludes) = hash(inc.fsize, UInt(inc.hash))
        end
    elseif VERSION >= v"1.6.0"
        using ..OrderedCollections
        using ..LoweredCodeUtils
        using ..CodeTracking
        using ..JuliaInterpreter
        using ..CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
        using ..JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return,
            @lookup, moduleof, scopeof, pc_expr, is_quotenode_egal,
            linetable, codelocs, LineTypes, isassign, isidentical
        using ..LoweredCodeUtils: next_or_nothing!, trackedheads, callee_matches

        include("../../../packages-old/v1.9/Revise/src/packagedef.jl")
    else
        using ..OrderedCollections
        using ..LoweredCodeUtils
        using ..CodeTracking
        using ..JuliaInterpreter
        using ..CodeTracking: PkgFiles, basedir, srcfiles, line_is_decl, basepath
        using ..JuliaInterpreter: whichtt, is_doc_expr, step_expr!, finish_and_return!, get_return,
            @lookup, moduleof, scopeof, pc_expr, is_quotenode_egal,
            linetable, codelocs, LineTypes, isassign, isidentical
        using ..LoweredCodeUtils: next_or_nothing!, trackedheads, callee_matches

        include("../../../packages-old/v1.5/Revise/src/packagedef.jl")
    end
end

module DebugAdapter
    import Pkg
    import ..JuliaInterpreter
    import ..JSON

    include("../../../packages/DebugAdapter/src/packagedef.jl")
end
