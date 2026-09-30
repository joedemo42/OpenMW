#ifndef OPENMW_COMPONENTS_CRASHCATCHER_CRASHCATCHER_HPP
#define OPENMW_COMPONENTS_CRASHCATCHER_CRASHCATCHER_HPP

#include <filesystem>

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if ((defined(__APPLE__) && !TARGET_OS_IPHONE) || (defined(__linux) && !defined(ANDROID))                              \
    || (defined(__unix) && !defined(ANDROID)) || defined(__posix))
void crashCatcherInstall(int argc, char** argv, const std::filesystem::path& crashLogPath);
#else
inline void crashCatcherInstall(int /*argc*/, char** /*argv*/, const std::filesystem::path& /*crashLogPath*/) {}
#endif

#endif
