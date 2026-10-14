#ifndef OPENMW_IOS_FIRSTLAUNCH_H
#define OPENMW_IOS_FIRSTLAUNCH_H

#include <filesystem>

namespace OMW
{
    /// iOS has no launcher or wizard: without <configDir>/openmw.cfg, imports <configDir>/Morrowind.ini with
    /// OpenMW's ini importer, the game data being in <configDir>/../Data (an ini only there is moved first).
    /// \return false if there is no openmw.cfg and none could be imported; the user was told what to copy where.
    bool ensureUserConfig(const std::filesystem::path& configDir);

    /// Until the user has tapped its button once: an alert that this is an unofficial port. The flag lives in the
    /// app's preferences (not in Documents): kept by app updates, removed with the app.
    void showUnofficialPortNotice();
}

#endif
