#ifndef OPENMW_IOS_FIRSTLAUNCH_H
#define OPENMW_IOS_FIRSTLAUNCH_H

#include <filesystem>

namespace OMW
{
    /// iOS has no launcher or wizard: without <configDir>/openmw.cfg, imports <configDir>/Morrowind.ini with
    /// OpenMW's ini importer, the game data being in <configDir>/../Data.
    /// \return false if there is no openmw.cfg and none could be imported; the user was told what to copy where.
    bool ensureUserConfig(const std::filesystem::path& configDir);
}

#endif
