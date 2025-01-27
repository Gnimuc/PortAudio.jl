# This file has runs the normal tests and also adds tests that can only be run
# locally on a machine with a sound card. It's mostly to put the library through
# its paces assuming a human is listening.

include("runtests.jl")

# these default values are specific to my machines
if Sys.iswindows()
    default_indev = "Microphone Array (Realtek High "
    default_outdev = "Speaker/Headphone (Realtek High"
elseif Sys.isapple()
    default_indev = "Built-in Microphone"
    default_outdev = "Built-in Output"
elseif Sys.islinux()
    default_indev = "default"
    default_outdev = "default"
end

@testset "Local Tests" begin
    @testset "Open Default Device" begin
        println("Recording...")
        stream = PortAudioStream(output_channels = 0)
        buf = read(stream, 5s)
        close(stream)
        @test size(buf) == (round(Int, 5 * samplerate(stream)), nchannels(stream.source))
        println("Playing back recording...")
        stream = PortAudioStream(;
            input_channels = 0, 
            output_channels = 2
        )
        write(stream, buf)
        println("flushing...")
        flush(stream)
        close(stream)
        println("Testing pass-through")
        stream = PortAudioStream()
        write(stream, stream, 5s)
        flush(stream)
        close(stream)
        println("done")
    end
    @testset "Samplerate-converting writing" begin
        stream = PortAudioStream(input_channels = 0)
        write(stream, SinSource(eltype(stream), samplerate(stream)*0.8, [220, 330]), 3s)
        write(stream, SinSource(eltype(stream), samplerate(stream)*1.2, [220, 330]), 3s)
        flush(stream)
        close(stream)
    end
    @testset "Open Device by name" begin
        stream = PortAudioStream(default_indev, default_outdev)
        buf = read(stream, 0.001s)
        @test size(buf) == (round(Int, 0.001 * samplerate(stream)), nchannels(stream.source))
        write(stream, buf)
        io = IOBuffer()
        show(io, stream)
        @test occursin("""
        PortAudioStream{Float32}
          Samplerate: 44100.0Hz
          Buffer Size: 4096 frames
          2 channel sink: "$default_outdev"
          2 channel source: "$default_indev\"""", String(take!(io)))
        close(stream)
    end
    @testset "Error on wrong name" begin
        @test_throws ErrorException PortAudioStream("foobarbaz")
    end
    # no way to check that the right data is actually getting read or written here,
    # but at least it's not crashing.
    @testset "Queued Writing" begin
        stream = PortAudioStream(input_channels = 0)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.sink))*0.1, samplerate(stream))
        t1 = @async write(stream, buf)
        t2 = @async write(stream, buf)
        @test fetch(t1) == 48000
        @test fetch(t2) == 48000
        flush(stream)
        close(stream)
    end
    @testset "Queued Reading" begin
        stream = PortAudioStream(output_channels = 0)
        buf = SampleBuf(rand(eltype(stream), 48000, nchannels(stream.source))*0.1, samplerate(stream))
        t1 = @async read!(stream, buf)
        t2 = @async read!(stream, buf)
        @test fetch(t1) == 48000
        @test fetch(t2) == 48000
        close(stream)
    end
end
