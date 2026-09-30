#ifndef COMPONENTS_FILES_IOSPATH_H
#define COMPONENTS_FILES_IOSPATH_H

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE

#include <filesystem>
#include <string>
#include <vector>

/**
 * \namespace Files
 */
namespace Files
{

    /**
     * \struct IosPath
     *
     * Files the user edits or keeps (config, logs, saves) live in the app's Documents directory, which the Files app
     * shows; everything else in the container's Library, as on macOS.
     */
    struct IosPath
    {
        IosPath(const std::string& application_name);

        /**
         * \brief Return path to the user config directory: Documents/Config.
         */
        std::filesystem::path getUserConfigPath() const;

        std::filesystem::path getUserDataPath() const;

        /**
         * \brief No global config: the app bundle's config is the local one.
         */
        std::filesystem::path getGlobalConfigPath() const;

        /**
         * \brief Return path to the openmw directory in the app bundle (read-only).
         */
        std::filesystem::path getLocalPath() const;

        std::filesystem::path getGlobalDataPath() const;

        std::filesystem::path getCachePath() const;

        std::vector<std::filesystem::path> getInstallPaths() const;

        std::filesystem::path getLogPath() const;

        std::filesystem::path getSavesPath() const;

        std::string mName;
    };

} /* namespace Files */

#endif /* defined(__APPLE__) && TARGET_OS_IPHONE */

#endif /* COMPONENTS_FILES_IOSPATH_H */
