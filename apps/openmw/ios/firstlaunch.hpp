#ifndef OPENMW_IOS_FIRSTLAUNCH_H
#define OPENMW_IOS_FIRSTLAUNCH_H

#include <components/files/multidircollection.hpp>

#include <filesystem>
#include <string>
#include <vector>

namespace OMW
{
    /// iOS has no launcher: without <configDir>/openmw.cfg, or when the Settings app asks for it, the setup assistant
    /// (ios/OpenMW/SetupAssistant.swift, the wizard's part) checks the game data in <configDir>/../Data, asks for the
    /// language and imports <configDir>/Morrowind.ini (an ini only in Data is moved first) with OpenMW's ini importer.
    /// Removes the missing.log of the last launch; the game files an import misses go into a new one.
    /// \return false if the setup assistant could not be shown
    bool ensureUserConfig(const std::filesystem::path& configDir);

    /// Each of \a files not in \a dirs (looked up as the engine does) goes into <configDir>/../missing.log as the
    /// place where the user copies it: "./Data/Morrowind.bsa".
    void reportMissingGameFiles(
        const std::filesystem::path& configDir, const Files::PathContainer& dirs, const std::vector<std::string>& files);

    /// Until the user has tapped its button once: an alert that this is an unofficial port. The flag lives in the
    /// app's preferences (not in Documents): kept by app updates, removed with the app.
    void showUnofficialPortNotice();
}

#endif
