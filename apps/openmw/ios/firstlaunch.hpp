#ifndef OPENMW_IOS_FIRSTLAUNCH_H
#define OPENMW_IOS_FIRSTLAUNCH_H

#include <components/files/multidircollection.hpp>

#include <filesystem>
#include <string>
#include <vector>

namespace OMW
{
    /// iOS has no launcher or wizard: without <configDir>/openmw.cfg, imports <configDir>/Morrowind.ini with
    /// OpenMW's ini importer, the game data being in <configDir>/../Data (an ini only there is moved first).
    /// Removes the missing.log of the last launch; missing ini and game files are reported to a new one.
    /// \return false if there is no openmw.cfg and none could be imported; the user was told what to copy where.
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
