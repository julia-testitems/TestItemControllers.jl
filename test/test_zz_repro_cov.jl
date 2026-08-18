@testitem "COVREPRO" setup=[TestHelpers] begin
    using TestItemControllers: filepath2uri

    pkg_path = ENV["COVREPRO_PKG"]
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = discovered.items

    coverage_root = filepath2uri(joinpath(pkg_path, "src"))

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        mode="Coverage",
        coverage_root_uris=[coverage_root],
        n_runs=1,
        timeout=900
    )

    src_uri = filepath2uri(joinpath(pkg_path, "src", basename(pkg_path) * ".jl"))

    for (idx, r) in enumerate(result.runs)
        cov = r.coverage
        if cov === nothing
            @info "RUN $idx: no coverage"
            continue
        end
        fc = filter(c -> c.uri == src_uri, cov)
        if length(fc) == 1
            v = fc[1].coverage
            covered = count(x -> x !== nothing && x > 0, v)
            coverable = count(x -> x !== nothing, v)
            @info "RUN $idx" pct=round(100*covered/coverable, digits=2) vec=string(v)
        else
            @info "RUN $idx: no entry for $src_uri" uris=string([c.uri for c in cov])
        end
    end

    @info "events" evts=string([e.event for e in result.events])
    @info "process events" evts=string([e.event for e in result.process_events])

    @test true
end
