#!/usr/bin/env julia

using PortAudio
using PortAudio: devices, handle_status, Pa_GetDeviceInfo, Pa_GetHostApiInfo, paNoError, paNotInitialized
using Test

@testset "PortAudio Tests" begin
    @testset "Reports version" begin
        io = IOBuffer()
        PortAudio.versioninfo(io)
        result = split(String(take!((io))), "\n")
        # make sure this is the same version I tested with
        @test startswith(result[1], "PortAudio V19")
    end

    @testset "Can list devices without crashing" begin
        devices()
    end
    @testset "Test error handling" begin
        @test_throws ErrorException Pa_GetDeviceInfo(-1)
        @test handle_status(paNoError) === nothing
        @test_throws ErrorException handle_status(paNotInitialized)
        @test_throws ErrorException Pa_GetHostApiInfo(-1)
    end
end
