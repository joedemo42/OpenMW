#include "firstlaunch.hpp"

#include <apps/mwiniimporter/importer.hpp>

#include <components/debug/debuglog.hpp>
#include <components/files/collections.hpp>
#include <components/files/conversion.hpp>
#include <components/misc/strings/algorithm.hpp>

#include <CoreFoundation/CoreFoundation.h>
#include <SDL_error.h>
#include <SDL_messagebox.h>

#include <algorithm>
#include <fstream>
#include <stdexcept>

namespace
{
    // the folder the user copies the game files into
    std::filesystem::path getDataDir(const std::filesystem::path& configDir)
    {
        return configDir.parent_path() / "Data";
    }

    std::filesystem::path getMissingLog(const std::filesystem::path& configDir)
    {
        return configDir.parent_path() / "missing.log";
    }

    // relative to the documents, as the Files app shows them: "./Data/Morrowind.bsa"
    void reportMissing(const std::filesystem::path& configDir, const std::filesystem::path& expected)
    {
        Log(Debug::Error) << "Missing " << expected;
        std::ofstream(getMissingLog(configDir), std::ios::app)
            << "./" << Files::pathToUnicodeString(expected.lexically_relative(configDir.parent_path())) << '\n';
    }

    bool missingGameFiles(const std::string& reason)
    {
        Log(Debug::Error) << reason;
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION, "Game files needed",
            "Copy the contents of Morrowind's \"Data Files\" folder into the app's Data folder and Morrowind.ini "
            "into its Config folder (Files app or Finder), then restart the app. The app's missing.log lists what "
            "is missing.",
            nullptr);
        return false;
    }
}

void OMW::reportMissingGameFiles(
    const std::filesystem::path& configDir, const Files::PathContainer& dirs, const std::vector<std::string>& files)
{
    // ponytail: always expected in Data, the only folder the user copies into; a hand-edited data= elsewhere would
    // need the matching dir here
    const Files::Collections collections(dirs);
    for (const std::string& file : files)
        if (!collections.doesExist(file))
            reportMissing(configDir, getDataDir(configDir) / file);
}

bool OMW::ensureUserConfig(const std::filesystem::path& configDir)
{
    // from the last launch; never stops this one
    std::error_code ec;
    std::filesystem::remove(getMissingLog(configDir), ec);

    const std::filesystem::path cfgFile = configDir / "openmw.cfg";
    if (std::filesystem::exists(cfgFile))
        return true;

    // the folders the user copies into
    const std::filesystem::path dataDir = getDataDir(configDir);
    std::filesystem::create_directories(configDir);
    std::filesystem::create_directories(dataDir);

    const std::filesystem::path iniFile = configDir / "Morrowind.ini";
    // on the PC the ini sits next to "Data Files": copied into Data along with them, it is moved where it belongs
    const std::filesystem::path dataIniFile = dataDir / "Morrowind.ini";
    if (!std::filesystem::exists(iniFile) && std::filesystem::exists(dataIniFile))
    {
        std::filesystem::rename(dataIniFile, iniFile);
        Log(Debug::Info) << "Moved " << dataIniFile << " to " << iniFile;
    }
    if (!std::filesystem::exists(iniFile))
    {
        reportMissing(configDir, iniFile);
        // only the ini names the game files: those of the wizard's Morrowind, Tribunal and Bloodmoon components
        // (apps/wizard/unshield/unshieldworker.cpp)
        reportMissingGameFiles(configDir, { dataDir },
            { "Morrowind.esm", "Morrowind.bsa", "Tribunal.esm", "Tribunal.bsa", "Bloodmoon.esm", "Bloodmoon.bsa" });
        return missingGameFiles("No " + Files::pathToUnicodeString(iniFile) + " to import");
    }

    // as the wizard runs openmw-iniimporter: --game-files --encoding win1252, no fonts
    // ponytail: win1252 (English/Western European game data); Polish/Russian data need win1250/win1251 here
    MwIniImporter importer;
    importer.setInputEncoding(ToUTF8::WINDOWS_1252);
    MwIniImporter::multistrmap cfg{ { "encoding", { "win1252" } },
        { "data", { Files::pathToUnicodeString(dataDir) } } };
    MwIniImporter::multistrmap ini = importer.loadIniFile(iniFile);
    ini.erase("Fonts:Font 0");
    ini.erase("Fonts:Font 1");
    ini.erase("Fonts:Font 2");
    importer.merge(cfg, ini);
    importer.mergeFallback(cfg, ini);
    importer.importGameFiles(cfg, ini, iniFile);
    importer.importArchives(cfg, ini);
    // the game files the importer did not find and dropped; the engine checks the imported archives
    for (const auto& [key, gameFiles] : ini)
        if (key.starts_with("Game Files:GameFile"))
            for (const std::string& file : gameFiles)
                if (std::ranges::none_of(cfg["content"],
                        [&](const std::string& content) { return Misc::StringUtils::ciEqual(content, file); }))
                    reportMissing(configDir, dataDir / file);
    if (cfg["content"].empty())
    {
        OMW::reportMissingGameFiles(configDir, { dataDir }, cfg["fallback-archive"]);
        return missingGameFiles(
            "No game file of " + Files::pathToUnicodeString(iniFile) + " in " + Files::pathToUnicodeString(dataDir));
    }

    // relative to the config dir: the app container's path changes with app updates
    cfg["data"] = { "\"../Data\"" };
    const std::filesystem::path tmpFile = configDir / "openmw.cfg.tmp";
    {
        std::ofstream file(tmpFile);
        MwIniImporter::writeToFile(file, cfg);
        file.close();
        if (!file)
            throw std::runtime_error("Failed to write " + Files::pathToUnicodeString(tmpFile));
    }
    std::filesystem::rename(tmpFile, cfgFile);
    Log(Debug::Info) << "Imported " << iniFile << " to " << cfgFile;
    return true;
}

void OMW::showUnofficialPortNotice()
{
    const CFStringRef key = CFSTR("UnofficialPortNoticeShown");
    if (CFPreferencesGetAppBooleanValue(key, kCFPreferencesCurrentApplication, nullptr))
        return;

    const SDL_MessageBoxButtonData button{ SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 0, "I understand." };
    const SDL_MessageBoxData notice{ SDL_MESSAGEBOX_INFORMATION, nullptr, "",
        "This is an unofficial port of OpenMW. Please don't bug the good people on the OpenMW Forums about it.", 1,
        &button, nullptr };
    int buttonId = -1;
    // not shown: again at the next start
    if (SDL_ShowMessageBox(&notice, &buttonId) != 0)
    {
        Log(Debug::Warning) << "Failed to show the unofficial port notice: " << SDL_GetError();
        return;
    }
    CFPreferencesSetAppValue(key, kCFBooleanTrue, kCFPreferencesCurrentApplication);
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
}
