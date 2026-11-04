module CoverageMergePackage

export first_item_only, second_item_only, never_called

# Each helper only ever runs inlined into its caller, so Julia counts its body lines but
# never its signature line.
@inline function first_helper(x)
    y = x + 1
    return y
end

first_item_only(x) = first_helper(x)

@inline function second_helper(x)
    y = 2x
    return y
end

second_item_only(x) = second_helper(x)

function never_called(x)
    y = x - 1
    return y
end

end # module CoverageMergePackage
