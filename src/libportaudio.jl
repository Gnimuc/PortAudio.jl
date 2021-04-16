# Low-level wrappers for Portaudio calls

# General type aliases
const PaTime = Cdouble
const PaError = Cint
const PaSampleFormat = Culong
const PaDeviceIndex = Cint
const PaHostApiIndex = Cint
const PaHostApiTypeId = Cint
# PaStream is always used as an opaque type, so we're always dealing
# with the pointer
const PaStream = Ptr{Cvoid}
const PaStreamCallback = Cvoid
const PaStreamFlags = Culong

const paNoFlag = PaStreamFlags(0x00)

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

# sample format types
const paFloat32 = PaSampleFormat(0x01)
const paInt32   = PaSampleFormat(0x02)
const paInt24   = PaSampleFormat(0x04)
const paInt16   = PaSampleFormat(0x08)
const paInt8    = PaSampleFormat(0x10)
const paUInt8   = PaSampleFormat(0x20)
const paNonInterleaved = PaSampleFormat(0x80000000)

const type_to_fmt = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32   => 2,
    # Int24   => 4,
    Int16   => 8,
    Int8    => 16,
    UInt8   => 3
)

const PaStreamCallbackResult = Cint
# Callback return values
const paContinue = PaStreamCallbackResult(0)
const paComplete = PaStreamCallbackResult(1)
const paAbort = PaStreamCallbackResult(2)

"""
Call the given expression in a separate thread, waiting on the result. This is
useful when running code that would otherwise block the Julia process (like a
`ccall` into a function that does IO).
"""
macro tcall(ex)
    :(fetch(Base.Threads.@spawn $(esc(ex))))
end

# because we're calling Pa_ReadStream and PA_WriteStream from separate threads,
# we put a mutex around libportaudio calls
const pamutex = ReentrantLock()

macro locked(ex)
    quote
        lock(pamutex) do
            $(esc(ex))
        end
    end
end

function Pa_Initialize()
    err = @locked @ccall libportaudio.Pa_Initialize()::PaError
    handle_status(err)
end

function Pa_Terminate()
    err = @locked @ccall libportaudio.Pa_Terminate()::PaError
    handle_status(err)
end

Pa_GetVersion() = @locked @ccall libportaudio.Pa_GetVersion()::Cint

function Pa_GetVersionText()
    versionPtr = @locked @ccall libportaudio.Pa_GetVersionText()::Ptr{Cchar}
    unsafe_string(versionPtr)
end

# Host API Functions

# A Host API is the top-level of the PortAudio hierarchy. Each host API has a
# unique type ID that tells you which native backend it is (JACK, ALSA, ASIO,
# etc.). On a given system you can identify each backend by its index, which
# will range between 0 and Pa_GetHostApiCount() - 1. You can enumerate through
# all the host APIs on the system by iterating through those values.

# PaHostApiTypeId values
const pa_host_api_names = Dict{PaHostApiTypeId, String}(
    0 => "In Development", # use while developing support for a new host API
    1 => "Direct Sound",
    2 => "MME",
    3 => "ASIO",
    4 => "Sound Manager",
    5 => "Core Audio",
    7 => "OSS",
    8 => "ALSA",
    9 => "AL",
    10 => "BeOS",
    11 => "WDMKS",
    12 => "Jack",
    13 => "WASAPI",
    14 => "AudioScience HPI"
)

mutable struct PaHostApiInfo
    struct_version::Cint
    api_type::PaHostApiTypeId
    name::Ptr{Cchar}
    deviceCount::Cint
    defaultInputDevice::PaDeviceIndex
    defaultOutputDevice::PaDeviceIndex
end

Pa_GetHostApiInfo(i) = unsafe_load(@locked @ccall libportaudio.Pa_GetHostApiInfo(i::PaHostApiIndex)::Ptr{PaHostApiInfo})

# Device Functions

mutable struct PaDeviceInfo
    struct_version::Cint
    name::Ptr{Cchar}
    host_api::PaHostApiIndex
    max_input_channels::Cint
    max_output_channels::Cint
    default_low_input_latency::PaTime
    default_low_output_latency::PaTime
    default_high_input_latency::PaTime
    default_high_output_latency::PaTime
    default_sample_rate::Cdouble
end

Pa_GetDeviceCount() = @locked @ccall libportaudio.Pa_GetDeviceCount()::PaDeviceIndex

Pa_GetDeviceInfo(i) = unsafe_load(@locked @ccall libportaudio.Pa_GetDeviceInfo(i::PaDeviceIndex)::Ptr{PaDeviceInfo})

Pa_GetDefaultInputDevice() = @locked @ccall libportaudio.Pa_GetDefaultInputDevice()::PaDeviceIndex

Pa_GetDefaultOutputDevice() = @locked @ccall libportaudio.Pa_GetDefaultOutputDevice()::PaDeviceIndex

# Stream Functions

mutable struct Pa_StreamParameters
    device::PaDeviceIndex
    channelCount::Cint
    sampleFormat::PaSampleFormat
    suggestedLatency::PaTime
    hostAPISpecificStreamInfo::Ptr{Cvoid}
end

mutable struct PaStreamInfo
    structVersion::Cint
    inputLatency::PaTime
    outputLatency::PaTime
    sampleRate::Cdouble
end

# function Pa_OpenDefaultStream(inChannels, outChannels,
#                               sampleFormat::PaSampleFormat,
#                               sampleRate, framesPerBuffer)
#     streamPtr = Ref{PaStream}(0)
#     err = @ccall libportaudio.Pa_OpenDefaultStream(
#         streamPtr::Ref{PaStream},
#         inChannels::Cint,
#         outChannels::Cint,
#         sampleFormat::PaSampleFormat,
#         sampleRate::Cdouble,
#         framesPerBuffer::Culong,
#         C_NULL::Ref{Cvoid},
#         C_NULL::Ref{Cvoid}
#     )::PaError
#     handle_status(err)
#
#     streamPtr[]
# end
#
function Pa_OpenStream(inParams, outParams,
                       sampleRate, framesPerBuffer,
                       flags::PaStreamFlags,
                       callback, userdata)
    streamPtr = Ref{PaStream}(0)
    err = @locked (@ccall libportaudio.Pa_OpenStream(
        streamPtr::Ref{PaStream},
        inParams::Ref{Pa_StreamParameters},
        outParams::Ref{Pa_StreamParameters},
        float(sampleRate)::Cdouble,
        framesPerBuffer::Culong,
        flags::PaStreamFlags,
        (callback === nothing ? C_NULL : callback)::Ref{Cvoid},
        (userdata === nothing ? C_NULL : pointer_from_objref(userdata))::Ptr{Cvoid}
    )::PaError),
    handle_status(err)
    streamPtr[]
end

function Pa_StartStream(stream::PaStream)
    err = @locked @ccall libportaudio.Pa_StartStream(stream::PaStream)::PaError
    handle_status(err)
end

function Pa_StopStream(stream::PaStream)
    err = @locked @ccall libportaudio.Pa_StopStream(stream::PaStream)::PaError
    handle_status(err)
end

function Pa_CloseStream(stream::PaStream)
    err = @locked @ccall libportaudio.Pa_CloseStream(stream::PaStream)::PaError
    handle_status(err)
end

function Pa_GetStreamReadAvailable(stream::PaStream)
    avail = @locked @ccall libportaudio.Pa_GetStreamReadAvailable(stream::PaStream)::Clong
    avail >= 0 || handle_status(avail)
    avail
end

function Pa_GetStreamWriteAvailable(stream::PaStream)
    avail = @locked @ccall libportaudio.Pa_GetStreamWriteAvailable(stream::PaStream)::Clong
    avail >= 0 || handle_status(avail)
    avail
end

function Pa_ReadStream(stream::PaStream, buf::Array, frames::Integer,
                       show_warnings=true)
    # without disable_sigint I get a segfault with the error:
    # "error thrown and no exception handler available."
    # if the user tries to ctrl-C. Note I've still had some crash problems with
    # ctrl-C within `pasuspend`, so for now I think either don't use `pasuspend` or
    # don't use ctrl-C.
    err = disable_sigint() do
        @tcall @locked @ccall libportaudio.Pa_ReadStream(stream::PaStream, buf::Ptr{Cvoid}, frames::Culong)::PaError
    end
    handle_status(err, show_warnings)
    err
end

function Pa_WriteStream(stream::PaStream, buf::Array, frames::Integer,
                        show_warnings=true)
    err = disable_sigint() do
        @tcall @locked @ccall libportaudio.Pa_WriteStream(stream::PaStream, buf::Ptr{Cvoid}, frames::Culong)::PaError
    end
    handle_status(err, show_warnings)
    err
end

# function Pa_GetStreamInfo(stream::PaStream)
#     infoptr = @ccall libportaudio.Pa_GetStreamInfo(stream::PaStream)::Ptr{PaStreamInfo}
#     unsafe_load(infoptr)
# end
#
# General utility function to handle the status from the Pa_* functions
function handle_status(err::PaError, show_warnings::Bool=true)
    if err == PA_OUTPUT_UNDERFLOWED || err == PA_INPUT_OVERFLOWED
        if show_warnings
            msg = @locked @ccall libportaudio.Pa_GetErrorText(err::PaError)::Ptr{Cchar}
            @warn("libportaudio: " * unsafe_string(msg))
        end
    elseif err != PA_NO_ERROR
        msg = @locked @ccall libportaudio.Pa_GetErrorText(err::PaError)::Ptr{Cchar}
        throw(ErrorException("libportaudio: " * unsafe_string(msg)))
    end
end
