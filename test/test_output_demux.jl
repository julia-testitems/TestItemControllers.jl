@testmodule DemuxHelpers begin
    using TestItemControllers: OutputDemuxer, feed!, flush!, OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

    export Run, frame, demux, demux_chunked, merged

    const Run = Pair{Union{Nothing,String},String}

    # The frame the test server writes around one item's output.
    frame(id, body) = string(OUTPUT_BEGIN_MARKER, id, '\x1f', body, OUTPUT_END_MARKER)

    # Adjacent runs for the same item joined, empty ones dropped — what a consumer sees
    # once it has appended everything, regardless of where the chunk boundaries fell.
    function merged(runs)
        out = Run[]
        for (id, text) in runs
            isempty(text) && continue
            if !isempty(out) && out[end].first == id
                out[end] = id => out[end].second * text
            else
                push!(out, id => text)
            end
        end
        return out
    end

    # Feed `stream` in chunks of the given byte sizes (the last one absorbs the remainder),
    # flush, and return the merged runs.
    function demux_chunked(stream::AbstractString, sizes)
        d = OutputDemuxer()
        bytes = Vector{UInt8}(codeunits(stream))
        runs = Run[]
        pos = 1
        for size in sizes
            pos > length(bytes) && break
            hi = min(pos + size - 1, length(bytes))
            append!(runs, feed!(d, bytes[pos:hi]))
            pos = hi + 1
        end
        pos <= length(bytes) && append!(runs, feed!(d, bytes[pos:end]))
        append!(runs, flush!(d))
        return merged(runs)
    end

    demux(stream::AbstractString) = demux_chunked(stream, [ncodeunits(stream)])
end

@testitem "Output demuxer attributes framed output to its test item" setup=[DemuxHelpers] begin
    stream = "booting\n" * frame("A", "hello\n") * "between\n" * frame("B", "world\n") * "done\n"

    @test demux(stream) == Run[
        nothing => "booting\n",
        "A" => "hello\n",
        nothing => "between\n",
        "B" => "world\n",
        nothing => "done\n",
    ]

    # Back-to-back frames, and frames with nothing in them.
    @test demux(frame("A", "") * frame("B", "x")) == Run["B" => "x"]
    @test demux("") == Run[]
end

@testitem "Output demuxer survives multi-byte characters (#101)" setup=[DemuxHelpers] begin
    # The report: a `✔` right before a `"` in the output, and an item id ending in one.
    id = "Genie@1234abcd/test/tests_markdown_rendering.jl::String markdown rendering ✔"
    stream = "✔\"quoted\" ✓\n" * frame(id, "✔ passed ✔\"\n") * "✔ done\n"

    runs = demux(stream)
    @test runs == Run[
        nothing => "✔\"quoted\" ✓\n",
        id => "✔ passed ✔\"\n",
        nothing => "✔ done\n",
    ]
    @test all(isvalid(r.second) for r in runs)
end

@testitem "Output demuxer keeps an id with quotes and multi-byte characters intact" setup=[DemuxHelpers] begin
    id = "Pkg@1234abcd/test/x.jl::handles \"quoted\" input ✔"
    @test demux(frame(id, "out\n")) == Run[id => "out\n"]
end

@testitem "Output demuxer is independent of where chunks split" setup=[DemuxHelpers] begin
    using Random

    id = "Pkg@1234abcd/test/x.jl::name ✔"
    stream = "✔ start\n" * frame(id, "✔✓ output ✔\n") * "mid ✓\n" * frame("B", "λ") * "✔ end"
    expected = demux(stream)
    @test length(expected) == 5

    # One byte at a time, and every fixed chunk size that puts a boundary inside a marker,
    # an id, or a character somewhere.
    for size in 1:40
        @test demux_chunked(stream, fill(size, ncodeunits(stream))) == expected
    end

    rng = MersenneTwister(101)
    for _ in 1:200
        sizes = rand(rng, 1:12, ncodeunits(stream))
        @test demux_chunked(stream, sizes) == expected
    end
end

@testitem "Output demuxer hands out valid UTF-8 whatever the chunking" setup=[DemuxHelpers] begin
    using TestItemControllers: OutputDemuxer, feed!, flush!

    stream = "✔ a\n" * frame("A ✔", "✔✔✔ λ\n") * "✓"
    bytes = Vector{UInt8}(codeunits(stream))

    d = OutputDemuxer()
    for b in bytes
        for (_, text) in feed!(d, [b])
            @test isvalid(text)
        end
    end
    @test isempty(flush!(d))
end

@testitem "Output demuxer holds back an incomplete character until it completes" setup=[DemuxHelpers] begin
    using TestItemControllers: OutputDemuxer, feed!, flush!

    check = Vector{UInt8}(codeunits("✔"))
    @test length(check) == 3

    d = OutputDemuxer()
    @test merged(feed!(d, check[1:1])) == Run[]
    @test merged(feed!(d, check[2:2])) == Run[]
    @test merged(feed!(d, check[3:3])) == Run[nothing => "✔"]

    # A four-byte character, split after two bytes.
    emoji = Vector{UInt8}(codeunits("🎉"))
    @test merged(feed!(d, vcat(codeunits("x"), emoji[1:2]))) == Run[nothing => "x"]
    @test merged(feed!(d, emoji[3:4])) == Run[nothing => "🎉"]

    # Whatever never completes is still output when the stream ends.
    @test merged(feed!(d, check[1:2])) == Run[]
    tail = flush!(d)
    @test length(tail) == 1
    @test codeunits(tail[1].second) == check[1:2]
    @test isempty(flush!(d))

    # Bytes that cannot be the start of a character are never held.
    @test merged(feed!(d, [0x80])) == Run[nothing => String([0x80])]
    @test merged(feed!(d, [0xff])) == Run[nothing => String([0xff])]
end

@testitem "Output demuxer holds a partial frame header until it completes" setup=[DemuxHelpers] begin
    using TestItemControllers: OutputDemuxer, feed!, flush!, OUTPUT_BEGIN_MARKER

    d = OutputDemuxer()
    @test merged(feed!(d, codeunits("a\n"))) == Run[nothing => "a\n"]
    # Half a marker: could still become one.
    @test merged(feed!(d, codeunits(OUTPUT_BEGIN_MARKER[1:10]))) == Run[]
    # The rest of the marker and part of the id, still no terminator.
    @test merged(feed!(d, codeunits(OUTPUT_BEGIN_MARKER[11:end] * "some id ✔"))) == Run[]
    @test merged(feed!(d, codeunits("\x1fout"))) == Run["some id ✔" => "out"]
    @test merged(flush!(d)) == Run[]
end

@testitem "Output demuxer passes frame bytes that are not markers through" setup=[DemuxHelpers] begin
    using TestItemControllers: OUTPUT_BEGIN_MARKER, OUTPUT_END_MARKER

    # A stray unit separator, and a prefix of a marker that turns out not to be one.
    @test demux("a\x1fb") == Run[nothing => "a\x1fb"]
    @test demux("a" * OUTPUT_BEGIN_MARKER[1:8] * "zzz") == Run[nothing => "a" * OUTPUT_BEGIN_MARKER[1:8] * "zzz"]

    # Inside a frame only the end marker counts; an end marker outside a frame is text.
    @test demux(frame("A", "x" * OUTPUT_BEGIN_MARKER * "y")) == Run["A" => "x" * OUTPUT_BEGIN_MARKER * "y"]
    @test demux("p" * OUTPUT_END_MARKER * "q") == Run[nothing => "p" * OUTPUT_END_MARKER * "q"]

    # A marker cut off by the end of the stream is output after all.
    @test demux("a" * OUTPUT_BEGIN_MARKER[1:20]) == Run[nothing => "a" * OUTPUT_BEGIN_MARKER[1:20]]
    @test demux(frame("A", "x") * OUTPUT_BEGIN_MARKER * "unterminated id") ==
        Run["A" => "x", nothing => OUTPUT_BEGIN_MARKER * "unterminated id"]
end

@testitem "Output demuxer never throws and loses no bytes on arbitrary input" setup=[DemuxHelpers] begin
    using Random
    using TestItemControllers: OutputDemuxer, feed!, flush!

    rng = MersenneTwister(7)
    for _ in 1:300
        bytes = rand(rng, UInt8, rand(rng, 0:400))
        # Random bytes never spell a 33-byte marker, so every byte must come back out, in
        # order, however the chunks fall.
        d = OutputDemuxer()
        out = UInt8[]
        pos = 1
        while pos <= length(bytes)
            hi = min(pos + rand(rng, 0:20), length(bytes))
            for (_, text) in feed!(d, bytes[pos:hi])
                append!(out, codeunits(text))
            end
            pos = hi + 1
        end
        for (_, text) in flush!(d)
            append!(out, codeunits(text))
        end
        @test out == bytes
    end

    # The same for streams that do contain frames, with random text around and inside them.
    for _ in 1:100
        text() = String(rand(rng, UInt8, rand(rng, 0:30)))
        stream = text() * frame(text(), text()) * text()
        d = OutputDemuxer()
        runs = feed!(d, Vector{UInt8}(codeunits(stream)))
        append!(runs, flush!(d))
        @test runs isa Vector
    end
end
