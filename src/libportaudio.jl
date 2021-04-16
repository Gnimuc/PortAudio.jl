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

const PA_NO_FLAG = PaStreamFlags(0x00)

const PA_NO_ERROR = 0
const PA_INPUT_OVERFLOWED = -10000 + 19
const PA_OUTPUT_UNDERFLOWED = -10000 + 20

const TYPE_TO_FORMAT = Dict{Type, PaSampleFormat}(
    Float32 => 1,
    Int32   => 2,
    # Int24   => 4,
    Int16   => 8,
    Int8    => 16,
    UInt8   => 32,
    # NonInterleaved => 2^31
)

const PaStreamCallbackResult = Cint

# Callback return values
@enum CallBackResult paContinue = 0 paComplete = 1 paAbort = 2

# because we're calling Pa_ReadStream and PA_WriteStream from separate threads,
# we put a mutex around libportaudio calls
const PA_MUTEX = ReentrantLock()

function Pa_Initialize()
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_Initialize()::PaError
    end)
end

function Pa_Terminate()
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_Terminate()::PaError
    end)
end

Pa_GetVersion() = lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetVersion()::Cint
end

function Pa_GetVersionText()
    unsafe_string(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_GetVersionText()::Ptr{Cchar}
    end)
end

# Host API Functions

# A Host API is the top-level of the PortAudio hierarchy. Each host API has a
# unique type ID that tells you which native backend it is (JACK, ALSA, ASIO,
# etc.). On a given system you can identify each backend by its index, which
# will range between 0 and Pa_GetHostApiCount() - 1. You can enumerate through
# all the host APIs on the system by iterating through those values.

# PaHostApiTypeId values
const PA_HOST_API_NAMES = Dict{PaHostApiTypeId, String}(
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
    device_count::Cint
    default_input_device::PaDeviceIndex
    default_output_device::PaDeviceIndex
end

Pa_GetHostApiInfo(index) = unsafe_load(lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetHostApiInfo(index::PaHostApiIndex)::Ptr{PaHostApiInfo}
end)

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

Pa_GetDeviceCount() = lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetDeviceCount()::PaDeviceIndex
end

Pa_GetDeviceInfo(index) = unsafe_load(lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetDeviceInfo(index::PaDeviceIndex)::Ptr{PaDeviceInfo}
end)

Pa_GetDefaultInputDevice() = lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetDefaultInputDevice()::PaDeviceIndex
end

Pa_GetDefaultOutputDevice() = lock(PA_MUTEX) do 
    @ccall libportaudio.Pa_GetDefaultOutputDevice()::PaDeviceIndex
end

# Stream Functions

mutable struct Pa_StreamParameters
    device::PaDeviceIndex
    channel_count::Cint
    sample_format::PaSampleFormat
    suggested_latency::PaTime
    host_API_specific_stream_info::Ptr{Cvoid}
end

mutable struct PaStreamInfo
    struct_version::Cint
    input_latency::PaTime
    output_latency::PaTime
    the_sample_rate::Cdouble
end

# function Pa_OpenDefaultStream(in_channels, out_channels,
#                               sample_format::PaSampleFormat,
#                               the_sample_rate, frames_per_buffer)
#     stream_pointer = Ref{PaStream}(0)
#     handle_status(@ccall libportaudio.Pa_OpenDefaultStream(
#         stream_pointer::Ref{PaStream},
#         in_channels::Cint,
#         out_channels::Cint,
#         sample_format::PaSampleFormat,
#         the_sample_rate::Cdouble,
#         frames_per_buffer::Culong,
#         C_NULL::Ref{Cvoid},
#         C_NULL::Ref{Cvoid}
#     )::PaError)
#
#     stream_pointer[]
# end
#
function Pa_OpenStream(in_parameters, out_parameters,
                       the_sample_rate, frames_per_buffer,
                       flags::PaStreamFlags,
                       callback, userdata)
    stream_pointer = Ref{PaStream}(0)
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_OpenStream(
            stream_pointer::Ref{PaStream},
            in_parameters::Ref{Pa_StreamParameters},
            out_parameters::Ref{Pa_StreamParameters},
            float(the_sample_rate)::Cdouble,
            frames_per_buffer::Culong,
            flags::PaStreamFlags,
            (callback === nothing ? C_NULL : callback)::Ref{Cvoid},
            (userdata === nothing ? C_NULL : pointer_from_objref(userdata))::Ptr{Cvoid}
        )::PaError
    end)
    stream_pointer[]
end

function Pa_StartStream(stream::PaStream)
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_StartStream(stream::PaStream)::PaError
    end)
end

function Pa_StopStream(stream::PaStream)
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_StopStream(stream::PaStream)::PaError        
    end)
end

function Pa_CloseStream(stream::PaStream)
    handle_status(lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_CloseStream(stream::PaStream)::PaError
    end)
end

function Pa_GetStreamReadAvailable(stream::PaStream)
    available = lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_GetStreamReadAvailable(stream::PaStream)::Clong
    end
    available >= 0 || handle_status(available)
    available
end

function Pa_GetStreamWriteAvailable(stream::PaStream)
    available = lock(PA_MUTEX) do 
        @ccall libportaudio.Pa_GetStreamWriteAvailable(stream::PaStream)::Clong
    end
    available >= 0 || handle_status(available)
    available
end

function Pa_ReadStream(stream::PaStream, buf::Array, frames::Integer,
                       show_warnings=true)
    # without disable_sigint I get a segfault with the error:
    # "error thrown and no exception handler available."
    # if the user tries to ctrl-C. Note I've still had some crash problems with
    # ctrl-C within `pasuspend`, so for now I think either don't use `pasuspend` or
    # don't use ctrl-C.
    error_code = disable_sigint() do
        fetch(@spawn lock(PA_MUTEX) do 
            @ccall libportaudio.Pa_ReadStream(stream::PaStream, buf::Ptr{Cvoid}, frames::Culong)::PaError
        end)
    end
    handle_status(error_code, show_warnings)
    error_code
end

function Pa_WriteStream(stream::PaStream, buf::Array, frames::Integer,
                        show_warnings=true)
    error_code = disable_sigint() do
        fetch(@spawn lock(PA_MUTEX) do
            @ccall libportaudio.Pa_WriteStream(stream::PaStream, buf::Ptr{Cvoid}, frames::Culong)::PaError
        end)
    end
    handle_status(error_code, show_warnings)
    error_code
end

# function Pa_GetStreamInfo(stream::PaStream)
#     unsafe_load(@ccall libportaudio.Pa_GetStreamInfo(stream::PaStream)::Ptr{PaStreamInfo})
# end
#
# General utility function to handle the status from the Pa_* functions
function handle_status(error_code::PaError, show_warnings::Bool=true)
    if error_code == PA_OUTPUT_UNDERFLOWED || error_code == PA_INPUT_OVERFLOWED
        if show_warnings
            @warn("libportaudio: " * unsafe_string(lock(PA_MUTEX) do
                @ccall libportaudio.Pa_GetErrorText(error_code::PaError)::Ptr{Cchar}
            end))
        end
    elseif error_code != PA_NO_ERROR
        throw(ErrorException("libportaudio: " * unsafe_string(lock(PA_MUTEX) do 
            @ccall libportaudio.Pa_GetErrorText(error_code::PaError)::Ptr{Cchar}
        end)))
    end
end
