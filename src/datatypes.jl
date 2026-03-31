function makechunks(X::AbstractVector, n::Integer)
    if n<1
        error("n is smaller than 1")
    end
    c = length(X) ÷ n
    return [X[1+c*k:(k == n-1 ? end : c*k+c)] for k = 0:n-1]
end

struct TestEnvironment
    id::String
    julia_cmd::String
    julia_args::Vector{String}
    julia_num_threads::Union{Nothing,String}
    julia_env::Dict{String,Union{String,Nothing}}
    mode::String   # "Normal", "Coverage", or "Debug"
    package_name::String
    package_uri::String
    project_uri::Union{Nothing,String}
    env_content_hash::Union{Nothing,String}
end

struct TestRunItem
    testitem_id::String
    test_env_id::String
    timeout::Union{Nothing,Float64}
    log_level::Symbol
end

struct TestItemDetail
    id::String
    uri::String
    label::String
    package_name::String
    package_uri::String
    option_default_imports::Bool
    test_setups::Vector{String}
    line::Int
    column::Int
    code::String
    code_line::Int
    code_column::Int
end

struct TestSetupDetail
    package_uri::String
    name::String
    kind::String
    uri::String
    line::Int
    column::Int
    code::String
end

struct TestMessageStackFrame
    label::String
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
    column::Union{Nothing,Int}
end

struct TestMessage
    message::String
    expected_output::Union{Nothing,String}
    actual_output::Union{Nothing,String}
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
    column::Union{Nothing,Int}
    stack_trace::Union{Nothing,Vector{TestMessageStackFrame}}
end

struct FileCoverage
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end
