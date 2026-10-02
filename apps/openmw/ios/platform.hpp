#ifndef OPENMW_IOS_PLATFORM_H
#define OPENMW_IOS_PLATFORM_H

namespace OMW
{
    /// iOS app setup before the engine starts SDL: home indicator, audio session, memory log,
    /// input device log.
    void initIosPlatform();
}

#endif
