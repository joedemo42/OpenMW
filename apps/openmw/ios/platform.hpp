#ifndef OPENMW_IOS_PLATFORM_H
#define OPENMW_IOS_PLATFORM_H

namespace OMW
{
    /// iOS app setup before the engine starts SDL: home indicator, audio session, memory log, gamepad-style menus
    /// and on-screen touch controls by the connected input devices.
    void initIosPlatform();

    /// The Settings app's "Log contents of Datafiles to file" (ios/OpenMW/Settings.bundle), now and whenever the app
    /// returns to the foreground: when on, it goes off and every folder and file in Documents/ goes into
    /// Documents/Datafiles-<date>.log ("./Data/Morrowind.esm<TAB><bytes>", like find, sorted).
    void initDataFilesLog();

    /// Apple's Metal Performance HUD as set in [Video] metal hud; after the settings are loaded, before the engine
    /// creates the window (Metal reads the HUD configuration when it creates the device).
    void configureMetalHud();
}

#endif
