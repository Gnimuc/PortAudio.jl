# This file has runs the normal tests and also adds tests that can only be run
# locally on a machine with a sound card. It's mostly to put the library through
# its paces assuming a human is listening.
using PortAudio

PortAudioStream(input(), output()) do input_buffer, output_buffer, framecount, time_info, callback_flags
    return paComplete
end
