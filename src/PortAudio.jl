module PortAudio

using alsa_plugins_jll: alsa_plugins_jll
using libportaudio_jll: libportaudio
using BitFlags: @bitflag

import Base: close, eltype, isopen, show

using Base.Threads: @spawn
using Base.Sys: islinux, iswindows

export PortAudioStream, input, output

include("libportaudio.jl")

# This size is in frames

# data is passed to and from portaudio in chunks with this many frames, because
# we need to interleave the samples
const CHUNK_FRAMES = 128

function versioninfo(io::IO = stdout)
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
        info.default_high_input_latency,
    ),
    PortAudioDeviceIO(
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
    for device in devices()
        if name(device) == device_name
            return device
        end
    end
    if device === nothing
        error(
            "No device matching \"$device_name\" found.\nAvailable Devices:\n$(device_names())",
        )
    end
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
    PortAudioDevice[
        PortAudioDevice(info, index - 1) for (index, info) in enumerate(
            PaDeviceInfo[Pa_GetDeviceInfo(index) for index = 0:(Pa_GetDeviceCount()-1)],
        )
    ]
end

# not for external use, used in error message printing
device_names() = join(["\"$(name(device))\"" for device in devices()], "\n")

struct Portal
    device::PortAudioDevice
    number_of_channels::Int
end

function Portal(device, device_IO::PortAudioDeviceIO;
    number_of_channels = 2
)
    Portal(
        device, 
        if number_of_channels === max
            device_IO.max_channels
        else
            number_of_channels
        end
    )
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

function nchannels(portal::Portal)
    portal.number_of_channels
end

function name(portal::Portal)
    name(portal.device)
end

mutable struct PortAudioStream{Sample}
    input_portal::Portal
    output_portal::Portal
    stream_pointer::PaStream
    the_sample_rate::Float64
    latency::Float64
end

function samplerate(stream::PortAudioStream)
    stream.the_sample_rate
end

function make_parameters(Sample, portal, latency)
    if portal === nothing
        C_NULL
    else
        Ref(
            Pa_StreamParameters(
                portal.device.index,
                nchannels(portal),
                TYPE_TO_FORMAT[Sample],
                latency,
                C_NULL,
            ),
        )
    end
end

function get_default_latency(input_portal, output_portal)
    if input_portal === nothing
        output_portal.device.output.high_latency
    elseif output_portal === nothing
        input_portal.device.input.high_latency
    else
        max(input_portal.device.input.high_latency, output_portal.device.output.high_latency)
    end
end

function get_default_sample_rate(
    input_portal,
    output_portal
)
    if input_portal === nothing
        output_portal.device.default_sample_rate
    elseif output_portal === nothing
        input_portal.device.default_sample_rate
    else
        sample_rate_input = input_portal.device.default_sample_rate
        sample_rate_output = output_portal.device.default_sample_rate
        if sample_rate_input != sample_rate_output
            error("Input and output devices differ in default sample rate. Pass an explicit sample rate to PortAudioStream")
        else
            sample_rate_input
        end
    end
end

function run_true_callback(
    input_buffer_pointer, 
    output_buffer_pointer, 
    framecount,
    time_info_pointer,
    status_flags,
    user_data_pointer
)
    PaStreamCallbackResult((unsafe_pointer_to_objref(user_data_pointer)::Function)(
        unsafe_wrap(Array, input_buffer_pointer, 2),
        unsafe_wrap(Array, output_buffer_pointer, 2),
        framecount,
        unsafe_pointer_to_objref(time_info_pointer),
        StreamCallbackFlags(status_flags),
    ))
end

function make_dummy_callback(::Type{Sample}) where {Sample}
    @cfunction(
        run_true_callback,
        PaStreamCallbackResult, # returns
        (
            Ptr{Sample}, # input buffer pointer
            Ptr{Sample}, # output buffer pointer
            Culong, # framecount
            Ptr{PaStreamCallbackTimeInfo}, # time info pointer
            PaStreamCallbackFlags, # status flags
            Ptr{Nothing}
        )
    )
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
function PortAudioStream(callback, input_portal, output_portal;
    Sample = Float32,
    the_sample_rate = get_default_sample_rate(input_portal, output_portal),
    latency = get_default_latency(input_portal, output_portal),
    userdata = nothing,
    frames_per_buffer = paFramesPerBufferUnspecified,
    flag = paNoFlag
)
    # finalizer(close, this)
    input_parameters = make_parameters(Sample, input_portal, latency)
    output_parameters = make_parameters(Sample, output_portal, latency)
    stream_pointer = Pa_OpenStream(
        input_parameters,
        output_parameters,
        the_sample_rate,
        frames_per_buffer,
        flag,
        make_dummy_callback(Sample),
        Ref(callback),
    )
    println("opened")
    Pa_StartStream(stream_pointer)
    println("started")
    # pre-fill the output stream so we're less likely to underrun
    PortAudioStream{Sample}(
        input_portal,
        output_portal,
        stream_pointer,
        the_sample_rate,
        latency
    )
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
eltype(::Type{PortAudioStream{Sample}}) where {Sample} = Sample

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
