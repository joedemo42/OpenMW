// Smoke tests of the scripting and media libraries (temporary, with osgtest.cpp): LuaJIT, ICU, OpenAL Soft and
// FFmpeg, used the way OpenMW uses them. One PASS/FAIL/SKIP line per check; returns the number of failures.
// dataDir (app argument, simulator: the host's game data) adds decoding of Morrowind's videos and MP3s.
#include <SDL2/SDL.h>

#include <AL/al.h>
#include <AL/alc.h>
#include <AL/alext.h>
#include <luajit-2.1/lua.hpp>
#include <unicode/errorcode.h>
#include <unicode/locid.h>
#include <unicode/msgfmt.h>
#include <unicode/uversion.h>

extern "C"
{
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <numbers>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace
{
    int failures = 0;

    void check(const std::string& name, bool ok, const std::string& detail = {})
    {
        if (!ok)
            ++failures;
        SDL_Log("%s %s%s%s", ok ? "PASS" : "FAIL", name.c_str(), detail.empty() ? "" : ": ", detail.c_str());
    }

    void checkLuaJit()
    {
        lua_State* lua = luaL_newstate();
        luaL_openlibs(lua);
        const char* chunk = R"(
            local squares = {}
            for i = 1, 100 do squares[i] = i * i end
            local sum = 0
            for _, v in ipairs(squares) do sum = sum + v end
            local words = {}
            for word in ("vivec almalexia sotha"):gmatch("%a+") do words[#words + 1] = word:upper() end
            local luaError = select(2, pcall(error, "boom"))
            local cError = pcall(string.rep) -- raised in C: longjmp through the interpreter
            return sum, table.concat(words, ","), luaError, cError, jit.version, jit.status()
        )";
        auto text = [&](int index) {
            const char* value = lua_tostring(lua, index);
            return std::string(value ? value : "");
        };
        bool ok = false;
        std::string detail;
        if (luaL_loadstring(lua, chunk) != 0 || lua_pcall(lua, 0, 6, 0) != 0)
            detail = text(-1);
        else
        {
            ok = lua_tointeger(lua, 1) == 338350 && text(2) == "VIVEC,ALMALEXIA,SOTHA"
                && text(3).find("boom") != std::string::npos && !lua_toboolean(lua, 4) && !lua_toboolean(lua, 6);
            detail = text(5) + ", jit " + (lua_toboolean(lua, 6) ? "on" : "off");
        }
        check("LuaJIT interpreter", ok, detail);
        lua_close(lua);
    }

    std::string format(const char* pattern, const char* locale, const char* name, const icu::Formattable& value)
    {
        icu::ErrorCode status;
        UParseError parseError;
        icu::MessageFormat message(icu::UnicodeString::fromUTF8(pattern), icu::Locale(locale), parseError, status);
        const icu::UnicodeString names[] = { icu::UnicodeString::fromUTF8(name) };
        icu::UnicodeString result;
        if (status.isSuccess())
            message.format(names, &value, 1, result, status);
        std::string utf8;
        result.toUTF8String(utf8);
        return status.isSuccess() ? utf8 : std::string("error ") + status.errorName();
    }

    void checkIcu()
    {
        // the calls OpenMW's l10n makes: MessageFormat with named arguments, plural rules, number formats
        const std::string en = format("{count, plural, one{# septim} other{# septims}}", "en", "count", 3);
        const std::string ru = format("{n, plural, one{# день} few{# дня} many{# дней} other{# дня}}", "ru", "n", 5);
        const std::string de = format("{value, number}", "de", "value", 1234.5);
        check("ICU MessageFormat", en == "3 septims" && ru == "5 дней" && de == "1.234,5",
            std::string(U_ICU_VERSION) + ": " + en + " | " + ru + " | " + de);
        icu::UnicodeString name;
        icu::Locale("de").getDisplayName(icu::Locale("en"), name);
        std::string utf8;
        SDL_Log("ICU display name of 'de' in English: '%s' (language names are filtered out)",
            name.toUTF8String(utf8).c_str());
    }

    void checkOpenAl()
    {
        ALCdevice* device = alcOpenDevice(nullptr);
        ALCcontext* context = device ? alcCreateContext(device, nullptr) : nullptr;
        if (!context || !alcMakeContextCurrent(context))
        {
            check("OpenAL device", false, device ? "no current context" : "no device");
            if (context)
                alcDestroyContext(context);
            if (device)
                alcCloseDevice(device);
            return;
        }
        ALCint frequency = 0;
        alcGetIntegerv(device, ALC_FREQUENCY, 1, &frequency);
        const ALCchar* deviceName = alcGetString(device, ALC_ALL_DEVICES_SPECIFIER);
        const std::string name = deviceName ? deviceName : "?";

        std::string missing;
        for (const char* extension : { "ALC_SOFT_PAUSE_DEVICE", "ALC_SOFT_reopen_device", "ALC_EXT_EFX", "ALC_SOFT_HRTF" })
            if (!alcIsExtensionPresent(device, extension))
                missing += std::string(extension) + " ";
        for (const char* extension :
            { "AL_EXT_FLOAT32", "AL_EXT_MCFORMATS", "AL_SOFT_events", "AL_SOFT_source_spatialize" })
            if (!alIsExtensionPresent(extension))
                missing += std::string(extension) + " ";
        if (!alcIsExtensionPresent(nullptr, "ALC_ENUMERATE_ALL_EXT"))
            missing += "ALC_ENUMERATE_ALL_EXT";
        check("OpenAL extensions OpenMW uses", missing.empty(), missing);

        // 0.2 s 440 Hz at gain 0: the whole path through the CoreAudio backend, silently
        std::vector<short> tone(44100 / 5);
        for (size_t i = 0; i < tone.size(); ++i)
            tone[i] = static_cast<short>(8000 * std::sin(2 * std::numbers::pi * 440 * i / 44100.0));
        ALuint buffer = 0, source = 0;
        alGenBuffers(1, &buffer);
        alBufferData(buffer, AL_FORMAT_MONO16, tone.data(), static_cast<ALsizei>(tone.size() * sizeof(short)), 44100);
        alGenSources(1, &source);
        alSourcei(source, AL_BUFFER, static_cast<ALint>(buffer));
        alSourcef(source, AL_GAIN, 0.f);
        alSourcePlay(source);
        ALint state = AL_PLAYING;
        for (int waited = 0; state == AL_PLAYING && waited < 2000; waited += 10)
        {
            SDL_Delay(10);
            alGetSourcei(source, AL_SOURCE_STATE, &state);
        }
        const ALenum error = alGetError();
        check("OpenAL playback", state == AL_STOPPED && error == AL_NO_ERROR,
            name + ", " + std::to_string(frequency) + " Hz" + (state == AL_STOPPED ? "" : ", source state not stopped")
                + (error == AL_NO_ERROR ? "" : ", AL error " + std::to_string(error)));
        alDeleteSources(1, &source);
        alDeleteBuffers(1, &buffer);
        alcMakeContextCurrent(nullptr);
        alcDestroyContext(context);
        alcCloseDevice(device);
    }

    // AVIO over a std::istream, as OpenMW reads through its VFS streams
    int readStream(void* opaque, uint8_t* data, int size)
    {
        std::istream& stream = *static_cast<std::istream*>(opaque);
        stream.read(reinterpret_cast<char*>(data), size);
        return stream.gcount() > 0 ? static_cast<int>(stream.gcount()) : AVERROR_EOF;
    }

    int64_t seekStream(void* opaque, int64_t offset, int whence)
    {
        std::istream& stream = *static_cast<std::istream*>(opaque);
        stream.clear();
        whence &= ~AVSEEK_FORCE;
        if (whence == AVSEEK_SIZE)
        {
            const std::streampos position = stream.tellg();
            stream.seekg(0, std::ios::end);
            const std::streampos size = stream.tellg();
            stream.seekg(position);
            return size;
        }
        stream.seekg(offset, whence == SEEK_CUR ? std::ios::cur : whence == SEEK_END ? std::ios::end : std::ios::beg);
        return stream.fail() ? -1 : static_cast<int64_t>(stream.tellg());
    }

    struct Decoded
    {
        std::set<std::string> codecs;
        int videoFrames = 0;
        int64_t audioSamples = 0;
        bool rgba = false; // first video frame converted to RGBA by swscale
        std::string error;
    };

    // Demuxes with the named demuxer, decodes every stream, converts video to RGBA (swscale) and audio to
    // interleaved 16-bit stereo (swresample), as OpenMW's video player and sound decoder do. Stops after
    // maxVideoFrames video frames (0: whole file).
    Decoded decode(std::istream& stream, const char* demuxer, int maxVideoFrames)
    {
        Decoded result;
        constexpr int bufferSize = 8192;
        AVIOContext* io = avio_alloc_context(
            static_cast<unsigned char*>(av_malloc(bufferSize)), bufferSize, 0, &stream, readStream, nullptr, seekStream);
        AVFormatContext* format = avformat_alloc_context();
        format->pb = io;
        if (avformat_open_input(&format, "", av_find_input_format(demuxer), nullptr) != 0
            || avformat_find_stream_info(format, nullptr) < 0)
            result.error = "open failed";
        std::vector<AVCodecContext*> decoders(result.error.empty() ? format->nb_streams : 0, nullptr);
        for (size_t i = 0; i < decoders.size(); ++i)
        {
            const AVCodecParameters* parameters = format->streams[i]->codecpar;
            const AVCodec* codec = avcodec_find_decoder(parameters->codec_id);
            if (!codec)
            {
                result.error = std::string("no decoder for ") + avcodec_get_name(parameters->codec_id);
                continue;
            }
            decoders[i] = avcodec_alloc_context3(codec);
            avcodec_parameters_to_context(decoders[i], parameters);
            if (avcodec_open2(decoders[i], codec, nullptr) < 0)
                result.error = std::string("cannot open ") + codec->name;
            result.codecs.insert(codec->name);
        }

        AVPacket* packet = av_packet_alloc();
        AVFrame* frame = av_frame_alloc();
        SwrContext* resampler = nullptr;
        std::vector<int16_t> samples;
        while (result.error.empty() && (maxVideoFrames == 0 || result.videoFrames < maxVideoFrames)
            && av_read_frame(format, packet) >= 0)
        {
            AVCodecContext* decoder = static_cast<size_t>(packet->stream_index) < decoders.size()
                ? decoders[packet->stream_index]
                : nullptr;
            if (decoder && avcodec_send_packet(decoder, packet) < 0)
                result.error = "send_packet failed";
            while (decoder && result.error.empty() && avcodec_receive_frame(decoder, frame) >= 0)
            {
                if (decoder->codec_type == AVMEDIA_TYPE_VIDEO && result.videoFrames++ == 0)
                {
                    SwsContext* scaler = sws_getContext(frame->width, frame->height,
                        static_cast<AVPixelFormat>(frame->format), frame->width, frame->height, AV_PIX_FMT_RGBA,
                        SWS_BICUBIC, nullptr, nullptr, nullptr);
                    uint8_t* rgba[4] = {};
                    int linesize[4] = {};
                    if (scaler
                        && av_image_alloc(rgba, linesize, frame->width, frame->height, AV_PIX_FMT_RGBA, 1) >= 0)
                    {
                        result.rgba = sws_scale(scaler, frame->data, frame->linesize, 0, frame->height, rgba,
                                          linesize)
                            == frame->height;
                        av_freep(&rgba[0]);
                    }
                    sws_freeContext(scaler);
                }
                else if (decoder->codec_type == AVMEDIA_TYPE_AUDIO)
                {
                    if (!resampler)
                    {
                        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
                        if (swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_S16, decoder->sample_rate,
                                &decoder->ch_layout, decoder->sample_fmt, decoder->sample_rate, 0, nullptr)
                                < 0
                            || swr_init(resampler) < 0)
                            result.error = "swresample init failed";
                    }
                    samples.resize(2 * (frame->nb_samples + 64));
                    uint8_t* out = reinterpret_cast<uint8_t*>(samples.data());
                    const int converted = resampler ? swr_convert(resampler, &out, frame->nb_samples + 64,
                                              frame->extended_data, frame->nb_samples)
                                                    : -1;
                    if (converted < 0 && result.error.empty())
                        result.error = "swr_convert failed";
                    result.audioSamples += std::max(converted, 0);
                }
            }
            av_packet_unref(packet);
        }
        swr_free(&resampler);
        av_frame_free(&frame);
        av_packet_free(&packet);
        for (AVCodecContext*& decoder : decoders)
            avcodec_free_context(&decoder);
        avformat_close_input(&format);
        av_freep(&io->buffer);
        avio_context_free(&io);
        return result;
    }

    std::string wav(int rate, int count) // 16-bit mono PCM, 440 Hz
    {
        std::ostringstream out;
        auto u32 = [&](uint32_t v) { out.write(reinterpret_cast<const char*>(&v), 4); };
        auto u16 = [&](uint16_t v) { out.write(reinterpret_cast<const char*>(&v), 2); };
        out << "RIFF";
        u32(36 + 2 * count);
        out << "WAVEfmt ";
        u32(16), u16(1), u16(1), u32(rate), u32(2 * rate), u16(2), u16(16);
        out << "data";
        u32(2 * count);
        for (int i = 0; i < count; ++i)
            u16(static_cast<uint16_t>(static_cast<int16_t>(8000 * std::sin(2 * std::numbers::pi * 440 * i / rate))));
        return out.str();
    }

    std::string describe(const Decoded& decoded, double ms)
    {
        std::string codecs;
        for (const std::string& codec : decoded.codecs)
            codecs += codec + " ";
        return codecs + std::to_string(decoded.videoFrames) + " frames, " + std::to_string(decoded.audioSamples)
            + " samples, " + std::to_string(int(ms)) + " ms" + (decoded.error.empty() ? "" : ", " + decoded.error);
    }

    double elapsedMs(std::chrono::steady_clock::time_point start)
    {
        return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    }

    void checkFfmpeg(const std::string& dataDir)
    {
        av_log_set_level(AV_LOG_ERROR);
        std::string missing;
        for (AVCodecID id : { AV_CODEC_ID_BINKVIDEO, AV_CODEC_ID_BINKAUDIO_DCT, AV_CODEC_ID_BINKAUDIO_RDFT,
                 AV_CODEC_ID_MP3, AV_CODEC_ID_PCM_S16LE })
            if (!avcodec_find_decoder(id))
                missing += std::string(avcodec_get_name(id)) + " ";
        for (const char* demuxer : { "bink", "mp3", "wav" })
            if (!av_find_input_format(demuxer))
                missing += std::string(demuxer) + " demuxer ";
        check("FFmpeg components", missing.empty(), std::string(av_version_info()) + (missing.empty() ? "" : ", missing ") + missing);

        std::istringstream generated(wav(22050, 2205));
        const Decoded pcm = decode(generated, "wav", 0);
        check("FFmpeg WAV via custom AVIO + swresample",
            pcm.error.empty() && pcm.audioSamples == 2205 && pcm.codecs.count("pcm_s16le"), describe(pcm, 0));

        if (dataDir.empty() || !std::filesystem::is_directory(dataDir))
        {
            SDL_Log("SKIP FFmpeg game data decoding (no data directory argument)");
            return;
        }
        std::vector<std::filesystem::path> videos, music, voices;
        for (const auto& entry : std::filesystem::recursive_directory_iterator(dataDir))
        {
            std::string extension = entry.path().extension().string();
            std::transform(extension.begin(), extension.end(), extension.begin(), ::tolower);
            const std::string path = entry.path().string();
            if (extension == ".bik")
                videos.push_back(entry.path());
            else if (extension == ".mp3" && path.find("/Music/") != std::string::npos)
                music.push_back(entry.path());
            else if (extension == ".mp3" && path.find("/Sound/") != std::string::npos)
                voices.push_back(entry.path());
        }
        std::sort(videos.begin(), videos.end());
        std::sort(music.begin(), music.end());
        std::sort(voices.begin(), voices.end());

        // every video: its first 100 frames with the audio in between
        std::set<std::string> codecs;
        std::string errors;
        const auto start = std::chrono::steady_clock::now();
        for (const auto& video : videos)
        {
            std::ifstream stream(video, std::ios::binary);
            const Decoded decoded = decode(stream, "bink", 100);
            codecs.insert(decoded.codecs.begin(), decoded.codecs.end());
            if (!decoded.error.empty() || decoded.videoFrames == 0 || !decoded.rgba)
                errors += video.filename().string() + ": " + describe(decoded, 0) + "; ";
        }
        std::string used;
        for (const std::string& codec : codecs)
            used += codec + " ";
        check("FFmpeg Bink videos (first 100 frames each)",
            !videos.empty() && errors.empty() && codecs.count("binkvideo") && codecs.count("binkaudio_dct")
                && codecs.count("binkaudio_rdft"),
            std::to_string(videos.size()) + " files, " + used + std::to_string(int(elapsedMs(start))) + " ms " + errors);

        for (const auto* list : { &music, &voices })
        {
            if (list->empty())
            {
                check("FFmpeg MP3", false, "no file found");
                continue;
            }
            std::ifstream stream(list->front(), std::ios::binary);
            const auto begin = std::chrono::steady_clock::now();
            const Decoded decoded = decode(stream, "mp3", 0);
            check("FFmpeg MP3 " + list->front().filename().string(),
                decoded.error.empty() && decoded.audioSamples > 0 && decoded.codecs.count("mp3float"),
                describe(decoded, elapsedMs(begin)));
        }
    }
}

int checkLibraries(const std::string& dataDir)
{
    checkLuaJit();
    checkIcu();
    checkOpenAl();
    checkFfmpeg(dataDir);
    return failures;
}
