#include "platform.hpp"

#include <components/debug/debuglog.hpp>

#include <SDL_hints.h>

#import <AVFAudio/AVFAudio.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <os/proc.h>

#include <cstdint>
#include <string>

namespace
{
    // footprint = what iOS counts against the app's memory limit; footprint + available = that limit
    void logMemory(const char* when)
    {
        constexpr std::uint64_t mb = 1024 * 1024;
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        const bool ok
            = task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS;
        Log(Debug::Info) << "Memory (" << when << "): footprint " << (ok ? info.phys_footprint / mb : 0) << " MB, peak "
                         << (ok ? info.ledger_phys_footprint_peak / mb : 0) << " MB, available "
                         << os_proc_available_memory() / mb << " MB";
    }

    // console-style menus unless a keyboard or mouse is connected without a game controller
    bool wantsControllerMenus()
    {
        const bool keyboardOrMouse = GCKeyboard.coalescedKeyboard != nil || GCMouse.mice.count > 0;
        return GCController.controllers.count > 0 || !keyboardOrMouse;
    }

    void logInputDevices(NSString* when)
    {
        std::string controllers;
        for (GCController* controller in GCController.controllers)
            controllers += std::string(controllers.empty() ? "" : ", ") + controller.productCategory.UTF8String;
        Log(Debug::Info) << "Input devices (" << when.UTF8String << "): keyboard "
                         << (GCKeyboard.coalescedKeyboard != nil ? "yes" : "no") << ", mice " << GCMouse.mice.count
                         << ", controllers [" << controllers << "] -> controller menus "
                         << (wantsControllerMenus() ? "on" : "off");
    }
}

void OMW::initIosPlatform()
{
    @autoreleasepool
    {
        // a swipe from the bottom edge first shows the home indicator, the second one leaves the game
        SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");

        // mixes with other apps' audio, muted by the silent switch
        NSError* error = nil;
        if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:&error])
            Log(Debug::Warning) << "Failed to set the audio session category: "
                                << error.localizedDescription.UTF8String;

        logMemory("launch");
        NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("memory warning"); }];
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification*) { logMemory("background"); }];

        logInputDevices(@"launch");
        for (NSString* name in @[ GCKeyboardDidConnectNotification, GCKeyboardDidDisconnectNotification,
                 GCMouseDidConnectNotification, GCMouseDidDisconnectNotification, GCControllerDidConnectNotification,
                 GCControllerDidDisconnectNotification ])
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification* notification) { logInputDevices(notification.name); }];
    }
}
