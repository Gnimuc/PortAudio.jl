const TYPE_TO_FORMAT = Dict{Type,PaSampleFormat}(
    Float32 => paFloat32,
    Int32 => paInt32,
    # Int24   => paInt24,
    Int16 => paInt16,
    Int8 => paInt8,
    UInt8 => paUInt8,
    # NonInterleaved => 2^31
)

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
const PA_MUTEX = ReentrantLock()

macro locked(ex)
    quote
        lock(PA_MUTEX) do
            $(esc(ex))
        end
    end
end

function Initialize()
    err = @locked Pa_Initialize()
    handle_status(err)
    return true
end

function Terminate()
    err = @locked Pa_Terminate()
    handle_status(err)
    return true
end

GetVersion() = @locked Pa_GetVersion()

function GetVersionText()
    char_ptr = @locked Pa_GetVersionText()
    return unsafe_string(char_ptr)
end

# Host API Functions

# A Host API is the top-level of the PortAudio hierarchy. Each host API has a
# unique type ID that tells you which native backend it is (JACK, ALSA, ASIO,
# etc.). On a given system you can identify each backend by its index, which
# will range between 0 and Pa_GetHostApiCount() - 1. You can enumerate through
# all the host APIs on the system by iterating through those values.

function GetHostApiInfo(i)
    ptr = @locked Pa_GetHostApiInfo(i)
    ptr == C_NULL && throw(ArgumentError("index out of range."))
    return unsafe_load(ptr)
end

# Device Functions
GetDeviceCount() = @locked Pa_GetDeviceCount()
GetDefaultInputDevice() = @locked Pa_GetDefaultInputDevice()
GetDefaultOutputDevice() = @locked Pa_GetDefaultOutputDevice()

function GetDeviceInfo(i)
    ptr = @locked Pa_GetDeviceInfo(i)
    ptr == C_NULL && throw(ArgumentError("index out of range."))
    return unsafe_load(ptr)
end


# Stream Functions
# function Pa_OpenDefaultStream(input_channels, output_channels,
#                               sample_format::PaSampleFormat,
#                               the_sample_rate, frames_per_buffer)
#     stream_pointer = Ref{Ptr{PaStream}}(0)
#     handle_status(@ccall libportaudio.Pa_OpenDefaultStream(
#         stream_pointer::Ref{Ptr{PaStream}},
#         input_channels::Cint,
#         output_channels::Cint,
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
function OpenStream(input_parameters, output_parameters, the_sample_rate, frames_per_buffer,
                    flags::PaStreamFlags, callback, userdata)
    stream_ref = Ref{Ptr{PaStream}}(C_NULL)
    err = @locked Pa_OpenStream(
                        stream_ref,
                        input_parameters,
                        output_parameters,
                        float(the_sample_rate),
                        frames_per_buffer,
                        flags,
                        callback === nothing ? C_NULL : callback,
                        userdata === nothing ? C_NULL : userdata,
                    )
    handle_status(err)
    return stream_ref[]
end

function simple_callback(input::Ptr{Cvoid}, output::Ptr{Cvoid}, frame_count::Culong,
    timeInfo::Ptr{PaStreamCallbackTimeInfo}, statusFlags::PaStreamCallbackFlags, userData)::Cint
    # push!(userData, frame_count)
    @show "ok"
    return Cint(paContinue)
end

function OpenStreamWithCallback(input_parameters, output_parameters,
    the_sample_rate, frames_per_buffer, flags::PaStreamFlags, callback, userdata)
    stream_ref = Ref{Ptr{PaStream}}(C_NULL)
    err = @locked ccall(
        (:Pa_OpenStream, libportaudio),
        PaError,
        (Ptr{Ptr{PaStream}}, Ptr{PaStreamParameters}, Ptr{PaStreamParameters}, Cdouble, Culong, PaStreamFlags, Ptr{Cvoid}, Any),
        stream_ref, input_parameters, output_parameters, float(the_sample_rate), frames_per_buffer, flags, callback, C_NULL,
    )
    handle_status(err)
    return stream_ref[]
end

function StartStream(stream::Ptr{PaStream})
    err = @locked Pa_StartStream(stream)
    handle_status(err)
    return err
end

function StopStream(stream::Ptr{PaStream})
    err = @locked Pa_StopStream(stream)
    handle_status(err)
    return true
end

function CloseStream(stream::Ptr{PaStream})
    err = @locked Pa_CloseStream(stream)
    handle_status(err)
    return true
end

function GetStreamReadAvailable(stream::Ptr{PaStream})
    available = @locked Pa_GetStreamReadAvailable(stream)
    available >= 0 || handle_status(available)
    return available
end

function GetStreamWriteAvailable(stream::Ptr{PaStream})
    available = @locked Pa_GetStreamWriteAvailable(stream)
    available >= 0 || handle_status(available)
    return available
end

function ReadStream(stream::Ptr{PaStream}, buf::Array, frames::Integer, show_warnings = true)
    # without disable_sigint I get a segfault with the error:
    # "error thrown and no exception handler available."
    # if the user tries to ctrl-C. Note I've still had some crash problems with
    # ctrl-C within `pasuspend`, so for now I think either don't use `pasuspend` or
    # don't use ctrl-C.
    err = disable_sigint() do
        @tcall @locked Pa_ReadStream(stream, buf, frames)
    end
    handle_status(err, show_warnings)
    return err
end

function WriteStream(stream::Ptr{PaStream}, buf::Array, frames::Integer, show_warnings = true)
    err = disable_sigint() do
        @tcall @locked Pa_WriteStream(stream, buf, frames)
    end
    handle_status(err, show_warnings)
    return err
end

# General utility function to handle the status from the Pa_* functions
function handle_status(err::PaErrorCode, show_warnings::Bool=true)
    if err == paOutputUnderflowed || err == paInputOverflowed
        if show_warnings
            msg = @locked Pa_GetErrorText(err)
            @warn("libportaudio: " * unsafe_string(msg))
        end
    elseif err != paNoError
        msg = @locked Pa_GetErrorText(err)
        throw(ErrorException("libportaudio: " * unsafe_string(msg)))
    end
    return nothing
end

handle_status(error_code::PaError, show_warnings::Bool = true) = handle_status(PaErrorCode(error_code), show_warnings)
