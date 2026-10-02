#ifndef OPENMW_IOS_PLATFORM_H
#define OPENMW_IOS_PLATFORM_H

namespace OMW
{
    /// iOS app setup before the engine starts SDL: home indicator, audio session, memory log, gamepad-style menus
    /// and on-screen touch controls by the connected input devices.
    void initIosPlatform();
}

#endif
