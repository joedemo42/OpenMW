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

extern "C"
{
    /// The import with an encoding ("win1252"): nullptr once openmw.cfg is written, else what went wrong (valid until
    /// the next call). The game files it misses are in missing.log.
    using OMWSetupImport = const char* (*)(void* context, const char* encoding);

    /// ios/OpenMW/SetupAssistant.swift: the setup pages over the app's scene until the user plays or keeps the current
    /// setup (\a configured: there is an openmw.cfg). \return false if they could not be shown
    bool OMWRunSetupAssistant(
        const char* documents, const char* encoding, bool configured, OMWSetupImport import, void* context);
}

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

    // as the wizard runs openmw-iniimporter: --game-files --encoding <the language's>, --cfg the existing openmw.cfg (its
    // lines stay, the content files, archives and the ini's settings are replaced), no fonts
    void importIni(const std::filesystem::path& configDir, const std::string& encoding)
    {
        // this import's
        std::error_code ec;
        std::filesystem::remove(getMissingLog(configDir), ec);

        const std::filesystem::path dataDir = getDataDir(configDir);
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
            throw std::runtime_error("Morrowind.ini is neither in the Config nor in the Data folder.");
        }

        const std::filesystem::path cfgFile = configDir / "openmw.cfg";
        MwIniImporter::multistrmap cfg;
        if (std::filesystem::exists(cfgFile))
            cfg = MwIniImporter::loadCfgFile(cfgFile);
        // relative to the config dir: the app container's path changes with app updates; the wizard adds its data dir
        // the same way
        std::vector<std::string> dataDirs = cfg["data"];
        if (std::ranges::find(dataDirs, "\"../Data\"") == dataDirs.end())
            dataDirs.push_back("\"../Data\"");
        // the importer looks the game files up relative to the working directory
        cfg["data"].clear();
        for (std::string dir : dataDirs)
        {
            if (dir.size() >= 2 && dir.front() == '"' && dir.back() == '"')
                dir = dir.substr(1, dir.size() - 2);
            if (!dir.empty())
                cfg["data"].push_back(Files::pathToUnicodeString(configDir / Files::pathFromUnicodeString(dir)));
        }

        MwIniImporter importer;
        importer.setInputEncoding(ToUTF8::calculateEncoding(encoding));
        cfg["encoding"] = { encoding };
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
            throw std::runtime_error("None of the game files Morrowind.ini lists is in the Data folder.");
        }

        cfg["data"] = dataDirs;
        const std::filesystem::path tmpFile = configDir / "openmw.cfg.tmp";
        {
            std::ofstream file(tmpFile);
            MwIniImporter::writeToFile(file, cfg);
            file.close();
            if (!file)
                throw std::runtime_error("Failed to write " + Files::pathToUnicodeString(tmpFile));
        }
        std::filesystem::rename(tmpFile, cfgFile);
        Log(Debug::Info) << "Imported " << iniFile << " to " << cfgFile << " (" << encoding << ")";
    }

    // the setup assistant's import; no exception may unwind through its Swift frames
    const char* importForSetupAssistant(void* context, const char* encoding)
    {
        static std::string error;
        try
        {
            importIni(*static_cast<const std::filesystem::path*>(context), encoding);
            return nullptr;
        }
        catch (const std::exception& e)
        {
            error = e.what();
            Log(Debug::Error) << "Import failed: " << error;
            return error.c_str();
        }
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

    // the Settings app's switch (ios/OpenMW/Settings.bundle), off again once the assistant opens
    const CFStringRef setupKey = CFSTR("SetupAssistantAtNextLaunch");
    const bool requested = CFPreferencesGetAppBooleanValue(setupKey, kCFPreferencesCurrentApplication, nullptr);
    const std::filesystem::path cfgFile = configDir / "openmw.cfg";
    const bool configured = std::filesystem::exists(cfgFile);
    if (configured && !requested)
        return true;
    if (requested)
    {
        CFPreferencesSetAppValue(setupKey, nullptr, kCFPreferencesCurrentApplication);
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    }

    // the folders the user copies into
    std::filesystem::create_directories(configDir);
    std::filesystem::create_directories(getDataDir(configDir));

    // the last import's language
    std::string encoding = "win1252";
    if (configured)
        if (const auto cfg = MwIniImporter::loadCfgFile(cfgFile); cfg.contains("encoding") && !cfg.at("encoding").empty())
            encoding = cfg.at("encoding").back();

    std::filesystem::path context = configDir;
    if (OMWRunSetupAssistant(Files::pathToUnicodeString(configDir.parent_path()).c_str(), encoding.c_str(), configured,
            importForSetupAssistant, &context))
        return true;
    Log(Debug::Error) << "Failed to show the setup assistant";
    return false;
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
