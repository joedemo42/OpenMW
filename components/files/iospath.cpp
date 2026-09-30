#include "iospath.hpp"

#if defined(__APPLE__) && TARGET_OS_IPHONE

#include <cstdlib>
#include <mach-o/dyld.h>
#include <stdexcept>

namespace
{
    // the app's container: Documents, Library, tmp
    std::filesystem::path getHome()
    {
        const char* dir = std::getenv("HOME");
        if (dir == nullptr)
            throw std::runtime_error("HOME is not set");
        return dir;
    }

    std::filesystem::path getBundlePath()
    {
        uint32_t size = 0;
        _NSGetExecutablePath(nullptr, &size);
        std::string path(size, '\0');
        if (_NSGetExecutablePath(path.data(), &size) != 0)
            throw std::runtime_error("Failed to get executable path");
        return std::filesystem::path(path.c_str()).parent_path();
    }
}

namespace Files
{

    IosPath::IosPath(const std::string& application_name)
        : mName(application_name)
    {
    }

    std::filesystem::path IosPath::getUserConfigPath() const
    {
        return getHome() / "Documents" / "Config";
    }

    std::filesystem::path IosPath::getUserDataPath() const
    {
        return getHome() / "Library" / "Application Support" / mName;
    }

    std::filesystem::path IosPath::getGlobalConfigPath() const
    {
        return {};
    }

    std::filesystem::path IosPath::getLocalPath() const
    {
        return getBundlePath() / "openmw";
    }

    std::filesystem::path IosPath::getGlobalDataPath() const
    {
        return {};
    }

    std::filesystem::path IosPath::getCachePath() const
    {
        return getHome() / "Library" / "Caches" / mName;
    }

    std::vector<std::filesystem::path> IosPath::getInstallPaths() const
    {
        return {};
    }

    std::filesystem::path IosPath::getLogPath() const
    {
        return getHome() / "Documents" / "Logs";
    }

    std::filesystem::path IosPath::getSavesPath() const
    {
        return getHome() / "Documents" / "Saves";
    }

    std::filesystem::path IosPath::getScreenshotPath() const
    {
        return getHome() / "Documents" / "Screenshots";
    }

} /* namespace Files */

#endif /* defined(__APPLE__) && TARGET_OS_IPHONE */
