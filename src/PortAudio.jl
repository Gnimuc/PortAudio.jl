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
const CHUNK_FRAMES=128

function versioninfo(io::IO=stdout)
    println(io, Pa_GetVersionText())
    println(io, "Version: ", Pa_GetVersion())
end

struct PortAudioDeviceIO
    max_channels::Int
    low_latency::Float64
    high_latency::Float64
end

mutable struct PortAudioDevice
    name::String
    host_api::String
    default_sample_rate::Float64
    index::PaDeviceIndex
    input::PortAudioDeviceIO
    output::PortAudioDeviceIO
end

PortAudioDevice(info::PaDeviceInfo, index) = PortAudioDevice(
    unsafe_string(info.name),
    unsafe_string(Pa_GetHostApiInfo(info.host_api).name),
    info.default_sample_rate,
    index,
    PortAudioDeviceIO(
        info.max_input_channels,
        info.default_low_input_latency,
        info.default_high_input_latency
    ),
    PortAudioDeviceIO(
        info.max_output_channels,
        info.default_low_output_latency,
        info.default_high_output_latency
    )
)

function devices()
    PortAudioDevice[PortAudioDevice(info, index-1) for (index, info) in enumerate(
        PaDeviceInfo[Pa_GetDeviceInfo(index) for index in 0:(Pa_GetDeviceCount() - 1)]
    )]
end

# not for external use, used in error message printing
device_names() = join(["\"$(device.name)\"" for device in devices()], "\n")

struct Portal{Sample}
    device::PortAudioDevice
    number_of_channels::Int
    chunk_buffer::Array{Sample, 2}
end

function Portal(device, number_of_channels; 
    Sample = Float32,
    chunk_buffer = zeros(Sample, channels, CHUNK_FRAMES)
)
    Portal{Sample}(device, number_of_channels, chunk_buffer)
end

nchannels(portal::Portal) = portal.number_of_channels
name(portal::Portal) = portal.device.name

#
# PortAudioStream
#

mutable struct PortAudioStream{Sample}
    the_sample_rate::Float64
    latency::Float64
    stream_pointer::PaStream
    warn_xruns::Bool
    recover_xruns::Bool
    sink_portal::Portal{Sample}
    source_portal::Portal{Sample}
end

function fill_max(channels, portal)
    if channels === max
        portal.max_channels
    else 
        channels
    end
end

function make_parameters(channels, device)
    if channels == 0
        Ptr{Pa_StreamParameters}(0)
    else
        Ref(Pa_StreamParameters(device.index, channels, TYPE_TO_FORMAT[Sample], latency, C_NULL))
    end
end

# this inner constructor is generally called via the top-level outer
# constructor below

# TODO: pre-fill outbut buffer on init
# TODO: recover from xruns - currently with low latencies (e.g. 0.01) it
# will run fine for a while and then fail with the first xrun.
# TODO: figure out whether we can get deterministic latency...
function PortAudioStream{Sample}(input_device::PortAudioDevice, output_device::PortAudioDevice,
    input_channels, output_channels, the_sample_rate,
    latency, warn_xruns, recover_xruns) where {Sample}
    input_channels = fill_max(input_channels, input_device.input)
    output_channels = fill_max(output_channels, output_device.output)
    # finalizer(close, this)
    input_parameters = make_parameters(input_channels, input_device)
    output_parameters = make_parameters(output_channels, output_device)
    stream_pointer = suppress_err() do
        Pa_OpenStream(
            input_parameters, 
            output_parameters, 
            the_sample_rate, 
            0, 
            PA_NO_FLAG, 
            nothing, 
            nothing
        )
    end
    Pa_StartStream(stream_pointer)
    # pre-fill the output stream so we're less likely to underrun
    stream = PortAudioStream(
        the_sample_rate,
        latency,
        stream_pointer,
        warn_xruns,
        recover_xruns,
        Portal(output_device, output_channels; Sample = Sample),
        Portal(input_device, input_channels; Sample = Sample)
    )
    prefill_output(stream)
    stream
end

function recover_xrun(stream::PortAudioStream)
    sink_portal = stream.sink_portal
    source_portal = stream.source_portal
    if nchannels(sink_portal) > 0 && nchannels(source_portal) > 0
        # the best we can do to avoid further xruns is to fill the playback buffer and
        # discard the capture buffer. Really there's a fundamental problem with our
        # read/write-based API where you don't know whether we're currently in a state
        # when the reads and writes should be balanced. In the future we should probably
        # move to some kind of transaction API that forces them to be balanced, and also
        # gives a way for the application to signal that the same number of samples
        # should have been read as written.
        discard_input(stream)
        prefill_output(stream)
    end
end

default_latency(devices...) = maximum(device -> max(device.input.high_latency, device.output.high_latency), devices)

function get_default_sample_rate(input_device, input_channels, output_device, output_channels)
    sample_rate_input = input_device.default_sample_rate
    sample_rate_output = output_device.default_sample_rate
    if input_channels > 0 && output_channels > 0 && sample_rate_input != sample_rate_output
        error("""
        Can't open duplex stream with mismatched samplerates (in: $sample_rate_input, out: $sample_rate_output).
                Try changing your sample rate in your driver settings or open separate input and output
                streams""")
    elseif input_channels > 0
        sample_rate_input
    else
        sample_rate_output
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
function PortAudioStream(input_device::PortAudioDevice, output_device::PortAudioDevice;
        input_channels = 2, 
        output_channels = 2, 
        eltype=Float32, 
        the_sample_rate = get_default_sample_rate(input_device, input_channels, output_device, output_channels),
        latency=default_latency(input_device, output_device), 
        warn_xruns=false, 
        recover_xruns=true
    )
    PortAudioStream{eltype}(input_device, output_device, input_channels, output_channels, the_sample_rate,
                            latency, warn_xruns, recover_xruns)
end

function get_device(device_name::String)
    for device in devices()
        if device.name == device_name
            return device
        end
    end
    if device === nothing
        error("No device matching \"$device_name\" found.\nAvailable Devices:\n$(device_names())")
    end
end

function get_device(index::Int)
    PortAudioDevice(Pa_GetDeviceInfo(index), index)
end

# handle device names given as streams
function PortAudioStream(input_device_name::AbstractString, output_device_name::AbstractString; keyword_arguments...)
    PortAudioStream(get_device(input_device_name), get_device(output_device_name); keyword_arguments...)
end

# if one device is given, use it for input and output, but set input_channels=0 so we
# end up with an output-only stream
function PortAudioStream(device;
    output_channels = 2; 
    keyword_arguments...
)
    PortAudioStream(device, device; input_channels = 0, output_channels = output_channels, keyword_arguments...)
end

# use the default input and output devices
function PortAudioStream(;
    input_channels = 2, 
    output_channels = 2; 
    keyword_arguments...
)
    input_index = Pa_GetDefaultInputDevice()
    output_index = Pa_GetDefaultOutputDevice()
    PortAudioStream(
        get_device(input_index), 
        get_device(output_index), 
        input_channels = input_channels, 
        output_channels = output_channels; 
        keyword_arguments...
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
eltype(::PortAudioStream{Sample}) where Sample = Sample

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

struct PortAudioSource <: SampleSource
    stream::PortAudioStream{Sample}
end

nchannels(sink::PortAudioSink) = nchannels(sink.stream.sink_portal)
nchannels(source::PortAudioSource) = nchannels(source.stream.source_portal)
samplerate(sink_or_source::Union{PortAudioSink, PortAudioSource}) = samplerate(sink_or_source.stream)
eltype(::Union{PortAudioSink{Sample}, PortAudioSource{Sample}}) where {Sample} = Sample
function close(sink_or_source::Union{PortAudioSink, PortAudioSource})
    close(sink_or_source.stream)
end
isopen(sink_or_source::Union{PortAudioSink, PortAudioSource}) = isopen(sink_or_source.stream)
name(sink::PortAudioSink) = name(sink.stream.sink_portal)
name(source::PortAudioSource) = name(source.stream.source_portal)

function show(io::IO, ::Type{PortAudioSink{Sample}}) where Sample
    print(io, "PortAudioSink{$Sample}")
end

function show(io::IO, ::Type{PortAudioSource{Sample}}) where Sample
    print(io, "PortAudioSource{$Sample}")
end

function show(io::IO, sink_or_source::SinkOrSource) where {SinkOrSource <: Union{PortAudioSink, PortAudioSource}}
    print(io, nchannels(sink_or_source), "-channel ", SinkOrSource, "(\"", name(sink_or_source), "\")")
end

function loop_copy()

function unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
    stream = sink.stream
    stream_pointer = stream.stream_pointer
    chunk_buffer = stream.sink_portal.chunk_buffer
    warn_xruns = stream.warn_xruns
    recover_xruns = stream.recover_xruns
    number_written = 0
    while number_written < framecount
        number = min(framecount-number_written, CHUNK_FRAMES)
        # make a buffer of interleaved samples
        transpose!(view(chunk_buffer, :, 1:number),
                   view(buf, (1:number) .+ number_written .+ frameoffset, :))
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_WriteStream(
            stream_pointer, 
            chunk_buffer, 
            number, 
            warn_xruns
        ) ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && recover_xruns
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
        number = min(framecount-number_read, CHUNK_FRAMES)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_ReadStream(
            stream_pointer, 
            chunk_buffer, 
            number,
            warn_xruns
        ) ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && recover_xruns
            recover_xrun(stream)
        end
        # de-interleave the samples
        transpose!(view(buf, (1:number) .+ number_read .+ frameoffset, :),
                   view(chunk_buffer, :, 1:number))

        number_read += number
    end

    number_read
end

"""
    prefill_output(stream::PortAudioStream)

Fill the playback buffer of the given sink.
"""
function prefill_output(stream::PortAudioStream)
    sink = stream.sink
    stream_pointer = sink.stream.stream_pointer
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

function suppress_err(do_function::Function)
    open((@static iswindows() ? "nul" : "/dev/null"), "w") do io
        redirect_stderr(do_function, io)
    end
end

function __init__()
    if islinux()
        config_key = "ALSA_CONFIG_DIR"
        if config_key ∉ keys(ENV)
            search_folders = ["/usr/share/alsa",
                          "/usr/local/share/alsa",
                          "/etc/alsa"]
            config_folder_index = findfirst(search_folders) do folder
                isfile(joinpath(folder, "alsa.conf"))
            end
            if config_folder_index === nothing
                throw(ErrorException(
                    """
                    Could not find ALSA config directory. Searched:
                    $(join(search_folders, "\n"))

                    if ALSA is installed, set the "ALSA_CONFIG_DIR" environment
                    variable. The given directory should have a file "alsa.conf".

                    If it would be useful to others, please file an issue at
                    https://github.com/JuliaAudio/PortAudio.jl/issues
                    with your alsa config directory so we can add it to the search
                    paths.
                    """))
            end
            ENV[config_key] = search_folders[config_folder_index]    
        end
        
        plugin_key = "ALSA_PLUGIN_DIR"
        if plugin_key ∉ keys(ENV) && alsa_plugins_jll.is_available()
            ENV[plugin_key] = joinpath(alsa_plugins_jll.artifact_dir, "lib", "alsa-lib")
        end
    end
    # initialize PortAudio on module load. libportaudio prints a bunch of
    # junk to STDOUT on initialization, so we swallow it.
    # TODO: actually check the junk to make sure there's nothing in there we
    # don't expect
    suppress_err() do
        Pa_Initialize()
    end

    atexit() do
        Pa_Terminate()
    end
end

end # module PortAudio
