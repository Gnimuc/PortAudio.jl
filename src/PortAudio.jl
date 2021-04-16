module PortAudio

using alsa_plugins_jll
using libportaudio_jll, SampledSignals

import Base: eltype, show
import Base: close, isopen
import Base: read, read!, write, flush

using Base.Threads: @spawn

import LinearAlgebra
import LinearAlgebra: transpose!

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

#
# PortAudioStream
#

mutable struct PortAudioStream{Sample}
    samplerate::Float64
    latency::Float64
    stream::PaStream
    warn_xruns::Bool
    recover_xruns::Bool
    sink # untyped because of circular type definition
    source # untyped because of circular type definition

    # this inner constructor is generally called via the top-level outer
    # constructor below

    # TODO: pre-fill outbut buffer on init
    # TODO: recover from xruns - currently with low latencies (e.g. 0.01) it
    # will run fine for a while and then fail with the first xrun.
    # TODO: figure out whether we can get deterministic latency...
    function PortAudioStream{Sample}(in_device::PortAudioDevice, out_device::PortAudioDevice,
                                in_channels, out_channels, the_sample_rate,
                                latency, warn_xruns, recover_xruns) where {Sample}
        in_channels = in_channels == -1 ? in_device.input.max_channels : in_channels
        out_channels = out_channels == -1 ? out_device.output.max_channels : out_channels
        this = new(the_sample_rate, latency, C_NULL, warn_xruns, recover_xruns)
        # finalizer(close, this)
        this.sink = PortAudioSink{Sample}(out_device.name, this, out_channels)
        this.source = PortAudioSource{Sample}(in_device.name, this, in_channels)
        this.stream = suppress_err() do
            Pa_OpenStream(
                (in_channels == 0) ?
                    Ptr{Pa_StreamParameters}(0) :
                    Ref(Pa_StreamParameters(in_device.index, in_channels, TYPE_TO_FORMAT[Sample], latency, C_NULL)), 
                (out_channels == 0) ?
                    Ptr{Pa_StreamParameters}(0) :
                    Ref(Pa_StreamParameters(out_device.index, out_channels, TYPE_TO_FORMAT[Sample], latency, C_NULL)), 
                the_sample_rate, 
                0, 
                PA_NO_FLAG, 
                nothing, 
                nothing
            )
        end

        Pa_StartStream(this.stream)
        # pre-fill the output stream so we're less likely to underrun
        prefill_output(this.sink)

        this
    end
end


function recover_xrun(stream::PortAudioStream)
    if nchannels(stream.sink) > 0 && nchannels(stream.source) > 0
        # the best we can do to avoid further xruns is to fill the playback buffer and
        # discard the capture buffer. Really there's a fundamental problem with our
        # read/write-based API where you don't know whether we're currently in a state
        # when the reads and writes should be balanced. In the future we should probably
        # move to some kind of transaction API that forces them to be balanced, and also
        # gives a way for the application to signal that the same number of samples
        # should have been read as written.
        discard_input(stream.source)
        prefill_output(stream.sink)
    end
end

default_latency(devices...) = maximum(device -> max(device.input.high_latency, device.output.high_latency), devices)

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
* `samplerate`:     Sample rate (defaults to device sample rate)
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
function PortAudioStream(in_device::PortAudioDevice, out_device::PortAudioDevice,
        in_channels=2, out_channels=2; eltype=Float32, samplerate=-1,
        latency=default_latency(in_device, out_device), warn_xruns=false, recover_xruns=true)
    if samplerate == -1
        sample_rate_in = in_device.default_sample_rate
        sample_rate_out = out_device.default_sample_rate
        if in_channels > 0 && out_channels > 0 && sample_rate_in != sample_rate_out
            error("""
            Can't open duplex stream with mismatched samplerates (in: $sample_rate_in, out: $sample_rate_out).
                   Try changing your sample rate in your driver settings or open separate input and output
                   streams""")
        elseif in_channels > 0
            samplerate = sample_rate_in
        else
            samplerate = sample_rate_out
        end
    end
    PortAudioStream{eltype}(in_device, out_device, in_channels, out_channels, samplerate,
                            latency, warn_xruns, recover_xruns)
end

# handle device names given as streams
function PortAudioStream(indevname::AbstractString, outdevname::AbstractString, arguments...; keyword_arguments...)
    in_device = nothing
    out_device = nothing
    for device in devices()
        if device.name == indevname
            in_device = device
        end
        if device.name == outdevname
            out_device = device
        end
    end
    if in_device == nothing
        error("No device matching \"$indevname\" found.\nAvailable Devices:\n$(device_names())")
    end
    if out_device == nothing
        error("No device matching \"$outdevname\" found.\nAvailable Devices:\n$(device_names())")
    end

    PortAudioStream(in_device, out_device, arguments...; keyword_arguments...)
end

# if one device is given, use it for input and output, but set in_channels=0 so we
# end up with an output-only stream
function PortAudioStream(device::PortAudioDevice, in_channels=2, out_channels=2; keyword_arguments...)
    PortAudioStream(device, device, in_channels, out_channels; keyword_arguments...)
end
function PortAudioStream(device::AbstractString, in_channels=2, out_channels=2; keyword_arguments...)
    PortAudioStream(device, device, in_channels, out_channels; keyword_arguments...)
end

# use the default input and output devices
function PortAudioStream(in_channels=2, out_channels=2; keyword_arguments...)
    in_index = Pa_GetDefaultInputDevice()
    out_index = Pa_GetDefaultOutputDevice()
    PortAudioStream(
        PortAudioDevice(Pa_GetDeviceInfo(in_index), in_index), 
        PortAudioDevice(Pa_GetDeviceInfo(out_index), out_index), 
        in_channels, 
        out_channels; 
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
    if stream.stream != C_NULL
        Pa_StopStream(stream.stream)
        Pa_CloseStream(stream.stream)
        stream.stream = C_NULL
    end

    nothing
end

isopen(stream::PortAudioStream) = stream.stream != C_NULL

SampledSignals.samplerate(stream::PortAudioStream) = stream.samplerate
eltype(::PortAudioStream{Sample}) where Sample = Sample

read(stream::PortAudioStream, arguments...) = read(stream.source, arguments...)
read!(stream::PortAudioStream, arguments...) = read!(stream.source, arguments...)
write(stream::PortAudioStream, arguments...) = write(stream.sink, arguments...)
write(sink::PortAudioStream, source::PortAudioStream, arguments...) = write(sink.sink, source.source, arguments...)
flush(stream::PortAudioStream) = flush(stream.sink)

function show(io::IO, stream::PortAudioStream)
    println(io, typeof(stream))
    println(io, "  Samplerate: ", samplerate(stream), "Hz")
    if nchannels(stream.sink) > 0
        print(io, "\n  ", nchannels(stream.sink), " channel sink: \"", name(stream.sink), "\"")
    end
    if nchannels(stream.source) > 0
        print(io, "\n  ", nchannels(stream.source), " channel source: \"", name(stream.source), "\"")
    end
end

#
# PortAudioSink & PortAudioSource
#

# Define our source and sink types
for (TypeName, Super) in ((:PortAudioSink, :SampleSink),
                          (:PortAudioSource, :SampleSource))
    @eval mutable struct $TypeName{Sample} <: $Super
        name::String
        stream::PortAudioStream{Sample}
        chunk_buffer::Array{Sample, 2}
        nchannels::Int

        function $TypeName{Sample}(name, stream, channels) where {Sample}
            # portaudio data comes in interleaved, so we'll end up transposing
            # it back and forth to julia column-major
            new(name, stream, zeros(Sample, channels, CHUNK_FRAMES), channels)
        end
    end
end

SampledSignals.nchannels(sink_or_source::Union{PortAudioSink, PortAudioSource}) = sink_or_source.nchannels
SampledSignals.samplerate(sink_or_source::Union{PortAudioSink, PortAudioSource}) = samplerate(sink_or_source.stream)
eltype(::Union{PortAudioSink{Sample}, PortAudioSource{Sample}}) where {Sample} = Sample
function close(sink_or_source::Union{PortAudioSink, PortAudioSource})
    throw(ErrorException("Attempted to close PortAudioSink or PortAudioSource.
                          Close the containing PortAudioStream instead"))
end
isopen(sink_or_source::Union{PortAudioSink, PortAudioSource}) = isopen(sink_or_source.stream)
name(sink_or_source::Union{PortAudioSink, PortAudioSource}) = sink_or_source.name

function show(io::IO, ::Type{PortAudioSink{Sample}}) where Sample
    print(io, "PortAudioSink{$Sample}")
end

function show(io::IO, ::Type{PortAudioSource{Sample}}) where Sample
    print(io, "PortAudioSource{$Sample}")
end

function show(io::IO, stream::SinkOrSource) where {SinkOrSource <: Union{PortAudioSink, PortAudioSource}}
    print(io, nchannels(stream), "-channel ", SinkOrSource, "(\"", stream.name, "\")")
end

function SampledSignals.unsafe_write(sink::PortAudioSink, buf::Array, frameoffset, framecount)
    number_written = 0
    while number_written < framecount
        number = min(framecount-number_written, CHUNK_FRAMES)
        # make a buffer of interleaved samples
        transpose!(view(sink.chunk_buffer, :, 1:number),
                   view(buf, (1:number) .+ number_written .+ frameoffset, :))
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_WriteStream(
            sink.stream.stream, 
            sink.chunk_buffer, 
            number, 
            sink.stream.warn_xruns
        ) ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && sink.stream.recover_xruns
            recover_xrun(sink.stream)
        end
        number_written += number
    end

    number_written
end

function SampledSignals.unsafe_read!(source::PortAudioSource, buf::Array, frameoffset, framecount)
    number_read = 0
    while number_read < framecount
        number = min(framecount-number_read, CHUNK_FRAMES)
        # TODO: if the stream is closed we just want to return a
        # shorter-than-requested frame count instead of throwing an error
        if Pa_ReadStream(
            source.stream.stream, 
            source.chunk_buffer, 
            number,
            source.stream.warn_xruns
        ) ∈ (PA_OUTPUT_UNDERFLOWED, PA_INPUT_OVERFLOWED) && source.stream.recover_xruns
            recover_xrun(source.stream)
        end
        # de-interleave the samples
        transpose!(view(buf, (1:number) .+ number_read .+ frameoffset, :),
                   view(source.chunk_buffer, :, 1:number))

        number_read += number
    end

    number_read
end

"""
    prefill_output(sink::PortAudioSink)

Fill the playback buffer of the given sink.
"""
function prefill_output(sink::PortAudioSink)
    to_write = Pa_GetStreamWriteAvailable(sink.stream.stream)
    while to_write > 0
        number = min(to_write, CHUNK_FRAMES)
        fill!(sink.chunk_buffer, zero(eltype(sink.chunk_buffer)))
        Pa_WriteStream(sink.stream.stream, sink.chunk_buffer, number, false)
        to_write -= number
    end
end

"""
    discard_input(source::PortAudioSource)

Read and discard data from the capture buffer.
"""
function discard_input(source::PortAudioSource)
    to_read = Pa_GetStreamReadAvailable(source.stream.stream)
    while to_read > 0
        number = min(to_read, CHUNK_FRAMES)
        Pa_ReadStream(source.stream.stream, source.chunk_buffer, number, false)
        to_read -= number
    end
end

function suppress_err(do_function::Function)
    open((@static Sys.iswindows() ? "nul" : "/dev/null"), "w") do io
        redirect_stderr(do_function, io)
    end
end

function __init__()
    if Sys.islinux()
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
