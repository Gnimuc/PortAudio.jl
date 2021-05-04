module PortAudio

using alsa_plugins_jll
using libportaudio_jll, SampledSignals

import Base: eltype, show
import Base: close, isopen
import Base: read, read!, write, flush

using Base.Threads: @spawn
using Base.Sys: islinux, iswindows

import LinearAlgebra
import LinearAlgebra: transpose!

import SampledSignals: nchannels, samplerate, unsafe_read!, unsafe_write

export PortAudioStream

include("libportaudio.jl")

# This size is in frames

# data is passed to and from portaudio in chunks with this many frames, because
# we need to interleave the samples
const CHUNK_FRAMES = 128

function versioninfo(io::IO = stdout)
    println(io, Pa_GetVersionText())
    println(io, "Version: ", Pa_GetVersion())
end

struct IOBounds
    max_channels::Int
    low_latency::Float64
    high_latency::Float64
end

mutable struct PortAudioDevice
    name::String
    host_api::String
    default_sample_rate::Float64
    index::PaDeviceIndex
    input::IOBounds
    output::IOBounds
end

PortAudioDevice(info::PaDeviceInfo, index) = PortAudioDevice(
    unsafe_string(info.name),
    unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
    info.default_sample_rate,
    index,
    IOBounds(
        info.max_input_channels,
        info.default_low_input_latency,
        info.default_high_input_latency,
    ),
    IOBounds(
        info.max_output_channels,
        info.default_low_output_latency,
        info.default_high_output_latency,
    ),
)

function name(device::PortAudioDevice)
    device.name
end

function get_device(device::PortAudioDevice)
    device
end

function get_device(device_name::AbstractString)
    devices[device_name]
end

function get_device(index::Integer)
    PortAudioDevice(Pa_GetDeviceInfo(index), index)
end

function show(io::IO, device::PortAudioDevice)
    print(io, 
        device.index,
        ": ",
        name(device)
    )
    max_input_channels = device.input.max_channels
    has_inputs = max_input_channels > 0
    max_output_channels = device.output.max_channels
    has_outputs = max_output_channels > 0
    if has_inputs || has_outputs
        print(io, " (")
        if has_inputs
            print(io, "in: ", max_input_channels)
        end
        if has_inputs && has_outputs
            print(io, ", ")
        end
        if has_outputs
            print(io, "out: ", max_output_channels)
        end
        print(io, ")")
    end
end

function devices()
    Dict(Iterators.map(
        function (index)
            device = PortAudioDevice(Pa_GetDeviceInfo(index), index)
            name(device) => device
        end,
        (1:Pa_GetDeviceCount()) .- 1
    ))
end

struct Portal{Sample}
    device::PortAudioDevice
    number_of_channels::Int
    chunk_buffer::Array{Sample,2}
end

function Portal(device, IO_bounds;
    number_of_channels = 2,
    Sample = Float32
)
    number_of_channels_filled = 
        if number_of_channels === max
            IO_bounds.max_channels
        else
            number_of_channels
        end
    Portal{Sample}(device, number_of_channels_filled, zeros(Sample, number_of_channels_filled, CHUNK_FRAMES))
end

function input(;
    device_id = Pa_GetDefaultInputDevice(),
    keyword_arguments...
)
    device = get_device(device_id)
    Portal(device, device.input; keyword_arguments...)
end

function output(;
    device_id = Pa_GetDefaultOutputDevice(),
    keyword_arguments...
)
    device = get_device(device_id)
    Portal(device, device.output; keyword_arguments...)
end

function eltype(::Type{Portal{Sample}}) where {Sample}
    Sample
end

function nchannels(portal::Portal)
    portal.number_of_channels
end
function name(portal::Portal)
    name(portal.device)
end

mutable struct PortAudioStream{Sample}
    input_portal::Portal{Sample}
    output_portal::Portal{Sample}
    stream_pointer::PaStream
    the_sample_rate::Float64
    latency::Float64
end

function make_parameters(portal, latency)
    if portal === nothing
        Ptr{Pa_StreamParameters}(0)
    else
        Ref(
            Pa_StreamParameters(
                portal.device.index,
                portal.number_of_channels,
                TYPE_TO_FORMAT[eltype(portal)],
                latency,
                C_NULL,
            ),
        )
    end
end

function get_default_latency(input_portal, output_portal)
    if input_portal === nothing
        if output_portal === nothing
            error("No devices!")
        else
            output_device.output.high_latency
        end
    elseif output_portal === nothing
        input_device.input.high_latency
    else
        max(input_device.input.high_latency, output_device.output.high_latency)
    end
end

function get_default_sample_rate(
    input_portal,
    output_portal
)
    if input_portal === nothing
        if output_portal === nothing
            error("No devices!")
        else
            output_portal.device.default_sample_rate
        end
    elseif output_portal === nothing
        input_portal.device.default_sample_rate
    else
        sample_rate_input = input_portal.device.default_sample_rate
        sample_rate_output = output_portal.device.default_sample_rate
        if sample_rate_input != sample_rate_output
            error("Input and output default sample rates do not match. Plese specify a sample rate.")
        else
            sample_rate_input
        end
    end
end

# this is the top-level outer constructor that all the other outer constructors end up calling
"""
    PortAudioStream(inchannels=2, outchannels=2; options...)
    PortAudioStream(duplexdevice, inchannels=2, outchannels=2; options...)
    PortAudioStream(indevice, outdevice, inchannels=2, outchannels=2; options...)

Audio devices can either be `PortAudioDevice` instances as returned
by `PortAudio.devices()`, or strings with the device name as reported by the
operating system. If a single `duplexdevice` is given it will be used for both
input and output. If no devices are given the system default devices will be
used.

Options:

* `eltype`:         Sample type of the audio stream (defaults to Float32)
* `the_sample_rate`:     Sample rate (defaults to device sample rate)
* `latency`:        Requested latency. Stream could underrun when too low, consider
                    using provided device defaults
* `warn_xruns`:     Display a warning if there is a stream overrun or underrun, which
                    often happens when Julia is compiling, or with a particularly large
                    GC run. This can be quite verbose so is false by default.
* `recover_xruns`:  Attempt to recover from overruns and underruns by emptying and
                    filling the input and output buffers, respectively. Should result in
                    fewer xruns but could make each xrun more audible. True by default.
                    Only effects duplex streams.
"""
function PortAudioStream(
    input_portal,
    output_portal;
    the_sample_rate = get_default_sample_rate(input_portal, output_portal),
    latency = get_default_latency(input_portal, output_portal)
)
    # finalizer(close, this)
    input_parameters = make_parameters(input_portal, latency)
    output_parameters = make_parameters(output_portal, latency)
    stream_pointer = Pa_OpenStream(
        input_parameters,
        output_parameters,
        the_sample_rate,
        0,
        PA_NO_FLAG,
        nothing,
        nothing,
    )
    Pa_StartStream(stream_pointer)
    # pre-fill the output stream so we're less likely to underrun
    stream = PortAudioStream(
        input_portal,
        output_portal,
        stream_pointer,
        the_sample_rate,
        latency
    )
end

# handle do-syntax
function PortAudioStream(do_function::Function, arguments...; keyword_arguments...)
    stream = PortAudioStream(arguments...; keyword_arguments...)
    try
        do_function(stream)
    finally
        close(stream)
    end
end

function close(stream::PortAudioStream)
    stream_pointer = stream.stream_pointer
    if stream_pointer != C_NULL
        Pa_StopStream(stream_pointer)
        Pa_CloseStream(stream_pointer)
        stream.stream_pointer = C_NULL
    end
    nothing
end

isopen(stream::PortAudioStream) = stream.stream_pointer != C_NULL

samplerate(stream::PortAudioStream) = stream.the_sample_rate
eltype(::PortAudioStream{Sample}) where {Sample} = Sample

read(stream::PortAudioStream, arguments...) = read(PortAudioSource(stream), arguments...)
read!(stream::PortAudioStream, arguments...) = read!(PortAudioSource(stream), arguments...)
write(stream::PortAudioStream, arguments...) = write(PortAudioSink(stream), arguments...)
write(sink_stream::PortAudioStream, source_stream::PortAudioStream, arguments...) =
    write(PortAudioSink(sink_stream), PortAudioSource(source_stream), arguments...)
flush(stream::PortAudioStream) = flush(PortAudioSink(stream))

function show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream), "Hz")
    sink_portal = stream.sink_portal
    sink_channels = nchannels(sink_portal)
    if sink_channels > 0
        print(io, "\n  ", sink_channels, " channel sink: \"", name(sink_portal), "\"")
    end
    source_portal = stream.source_portal
    source_channels = nchannels(source_portal)
    if source_channels > 0
        print(io, "\n  ", source_channels, " channel source: \"", name(source_portal), "\"")
    end
end

#
# PortAudioSink & PortAudioSource
#

# Define our source and sink types
struct PortAudioSink{Sample} <: SampleSink
    stream::PortAudioStream{Sample}
end

struct PortAudioSource{Sample} <: SampleSource
    stream::PortAudioStream{Sample}
end

nchannels(sink::PortAudioSink) = nchannels(sink.stream.sink_portal)
nchannels(source::PortAudioSource) = nchannels(source.stream.source_portal)
samplerate(sink_or_source::Union{PortAudioSink,PortAudioSource}) =
    samplerate(sink_or_source.stream)
eltype(::Union{Type{PortAudioSink{Sample}},Type{PortAudioSource{Sample}}}) where {Sample} = Sample
function close(sink_or_source::Union{PortAudioSink,PortAudioSource})
    close(sink_or_source.stream)
end
isopen(sink_or_source::Union{PortAudioSink,PortAudioSource}) = isopen(sink_or_source.stream)
name(sink::PortAudioSink) = name(sink.stream.sink_portal)
name(source::PortAudioSource) = name(source.stream.source_portal)

function show(io::IO, ::Type{PortAudioSink{Sample}}) where {Sample}
    print(io, "PortAudioSink{", Sample, "}")
end

function show(io::IO, ::Type{PortAudioSource{Sample}}) where {Sample}
    print(io, "PortAudioSource{", Sample, "{")
end

function show(
    io::IO,
    sink_or_source::SinkOrSource,
) where {SinkOrSource<:Union{PortAudioSink,PortAudioSource}}
    print(
        io,
        nchannels(sink_or_source),
        "-channel ",
        SinkOrSource,
        "(\"",
        name(sink_or_source),
        "\")",
    )
end

function unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
    stream = sink.stream
    stream_pointer = stream.stream_pointer
    chunk_buffer = stream.sink_portal.chunk_buffer
    warn_xruns = stream.warn_xruns
    recover_xruns = stream.recover_xruns
    number_written = 0
    while number_written < framecount
        number = min(framecount - number_written, CHUNK_FRAMES)
        # make a buffer of interleaved samples
        transpose!(
            view(chunk_buffer, :, 1:number),
            view(buf, (1:number) .+ number_written .+ frameoffset, :),
        )
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_WriteStream(stream_pointer, chunk_buffer, number, warn_xruns) ∈
           (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && recover_xruns
            recover_xrun(stream)
        end
        number_written += number
    end

    number_written
end

function unsafe_read!(source::PortAudioSource, buf::Array, frameoffset, framecount)
    stream = source.stream
    stream_pointer = stream.stream_pointer
    chunk_buffer = stream.source_portal.chunk_buffer
    warn_xruns = stream.warn_xruns
    recover_xruns = stream.recover_xruns
    number_read = 0
    while number_read < framecount
        number = min(framecount - number_read, CHUNK_FRAMES)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_ReadStream(stream_pointer, chunk_buffer, number, warn_xruns) ∈
           (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && recover_xruns
            recover_xrun(stream)
        end
        # de-interleave the samples
        transpose!(
            view(buf, (1:number) .+ number_read .+ frameoffset, :),
            view(chunk_buffer, :, 1:number),
        )

        number_read += number
    end

    number_read
end

"""
    prefill_output(stream::PortAudioStream)

Fill the playback buffer of the given sink.
"""
function prefill_output(stream::PortAudioStream)
    stream_pointer = stream.stream_pointer
    chunk_buffer = stream.sink_portal.chunk_buffer
    a_zero = zero(eltype(chunk_buffer))
    to_write = Pa_GetStreamWriteAvailable(stream_pointer)
    while to_write > 0
        number = min(to_write, CHUNK_FRAMES)
        fill!(chunk_buffer, a_zero)
        Pa_WriteStream(stream_pointer, chunk_buffer, number, false)
        to_write -= number
    end
end

"""
    discard_input(source::PortAudioSource)

Read and discard data from the capture buffer.
"""
function discard_input(stream::PortAudioStream)
    stream_pointer = stream.stream_pointer
    chunk_buffer = stream.source_portal.chunk_buffer
    to_read = Pa_GetStreamReadAvailable(stream_pointer)
    while to_read > 0
        number = min(to_read, CHUNK_FRAMES)
        Pa_ReadStream(stream_pointer, chunk_buffer, number, false)
        to_read -= number
    end
end

function seek_config(folders)
    for folder in folders
        if isfile(joinpath(folder, "alsa.conf"))
            return folder
        end
    end
    throw(
        ErrorException(
            """
            Could not find ALSA config directory. Searched:
            $(join(folders, "\n"))

            if ALSA is installed, set the "ALSA_CONFIG_DIR" environment
            variable. The given directory should have a file "alsa.conf".

            If it would be useful to others, please file an issue at
            https://github.com/JuliaAudio/PortAudio.jl/issues
            with your alsa config directory so we can add it to the search
            paths.
            """,
        ),
    )
end

const ALSA_CONFIG_DIRS = ["/usr/share/alsa", "/usr/local/share/alsa", "/etc/alsa"]

function __init__()
    if islinux()
        get!(ENV, "ALSA_CONFIG_DIR") do 
            seek_config(ALSA_CONFIG_DIRS)
        end
        if alsa_plugins_jll.is_available()
            get!(ENV, "ALSA_PLUGIN_DIR") do 
                joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
            end
        end
    end
    # initialize PortAudio on module load. libportaudio prints a bunch of
    # junk to STDOUT on initialization, so we swallow it.
    # TODO: actually check the junk to make sure there's nothing in there we
    # don't expect
    Pa_Initialize()

    atexit() do
        Pa_Terminate()
    end
end

end # module PortAudio
