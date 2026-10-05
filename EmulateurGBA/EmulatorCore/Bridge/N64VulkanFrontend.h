//
//  N64VulkanFrontend.h
//  EmulateurGBA
//
//  The Vulkan half of the N64 bridge: the part of a libretro frontend that a
//  hardware-rendered core needs, and nothing more. C++ only, included by
//  N64Bridge.mm and by no Swift-facing header.
//
//  WHAT IT DOES. parallel-RDP renders the N64's picture on the GPU with Vulkan.
//  A libretro core does not create its own Vulkan context; the frontend does,
//  and hands the core an interface to it. This class is that frontend, on
//  MoltenVK (Vulkan implemented on Metal):
//
//   1. it creates the VkInstance, and lets the CORE create the device through
//      libretro's context-negotiation interface, because parallel-RDP knows
//      which features and extensions it needs (8- and 16-bit storage, external
//      host memory) and we would only be guessing;
//   2. it answers the core's `retro_hw_render_interface_vulkan`: which queue to
//      submit on, a lock around it, and `set_image`, through which the core
//      says "this image is the frame";
//   3. after each frame, it copies that image into host memory and from there
//      into the bridge's framebuffer.
//
//  WHY A COPY, when Metal could sample the image directly (MoltenVK can export
//  a VkImage as its MTLTexture). Every consumer of a frame in this app reads the
//  CPU framebuffer: the Metal view's upload, the screenshot and clip share
//  cards, the save-slot previews, the widget and the external display. A
//  zero-copy texture would mean a second video path through all of them for one
//  console. The copy is one 640x480 (at most 640x576) RGBA frame, about 1.2 MB,
//  and only when the game presents a NEW picture, which most N64 games do 20 to
//  30 times a second. If the device spike shows it costs frames, the texture
//  export is the known next step and this class is where it goes.
//

#ifndef N64VulkanFrontend_h
#define N64VulkanFrontend_h

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

#include <vulkan/vulkan.h>
#include "libretro.h"
#include "libretro_vulkan.h"

class N64VulkanFrontend {
public:
    N64VulkanFrontend();
    ~N64VulkanFrontend();

    N64VulkanFrontend(const N64VulkanFrontend &) = delete;
    N64VulkanFrontend &operator=(const N64VulkanFrontend &) = delete;

    /// Step 1, called while the core is loading the game (from SET_HW_RENDER):
    /// creates the instance on MoltenVK and checks that the GPU has what
    /// parallel-RDP cannot run without, 8- and 16-bit access to storage
    /// buffers. Returns false, with the reason logged, if not.
    ///
    /// The check is here, and not left to the core, because of WHERE the core
    /// would find out. It checks those features when the game starts running,
    /// and its way out of a failed start ends the emulation coroutine by
    /// returning from it, which crashes. Refusing here instead makes the core
    /// fail the LOAD, which is the path it handles cleanly, and lets the app
    /// say the game cannot run on this device.
    bool createInstance();

    /// Step 2, called after the load succeeded: asks the core to create the
    /// device through its negotiation interface, and prepares the readback,
    /// `maxWidth` x `maxHeight` pixels. Returns false, with the reason logged,
    /// if any step fails; `destroy` is still safe to call.
    bool createDevice(const retro_hw_render_context_negotiation_interface_vulkan *negotiation,
                      unsigned maxWidth, unsigned maxHeight);

    /// Releases everything `create` made, in reverse order. The core's
    /// `context_destroy` must have been called first, so the core has let go of
    /// the device before the device goes away.
    void destroy();

    bool isReady() const { return _device != VK_NULL_HANDLE; }

    /// The interface the core fetches with GET_HW_RENDER_INTERFACE.
    const retro_hw_render_interface_vulkan *interface() const { return &_interface; }

    /// Copies the image the core named last through `set_image` into `dst`, as
    /// R,G,B,A bytes, `dstStridePixels` pixels per row. `width` and `height` are
    /// the ones the core passed to video_refresh, clamped to the readback
    /// buffer. Blocks until the GPU has finished the frame and the copy. Returns
    /// false if there is no image yet or the GPU did not finish in time.
    bool readFrame(unsigned width, unsigned height, uint32_t *dst, size_t dstStridePixels);

    /// Call before anything that can make the core run a frame (`retro_run`,
    /// and `retro_serialize`, `retro_unserialize` and `retro_reset`, which run
    /// one inside the core): waits until every Metal command buffer submitted
    /// so far has completed, then moves to the other sync index. See
    /// GetSyncIndex in the .mm for why the core's own wait is not enough.
    void beginFrame();

    /// Waits until every Metal command buffer submitted so far has completed.
    /// `beginFrame` does this; the bridge also calls it before the core tears
    /// its resources down, which frees them all at once.
    void drainQueue();

    /// True once a frame could not be read back in time: the picture stops
    /// updating for the rest of the session (see `_readbackLost`).
    bool readbackLost() const { return _readbackLost; }

private:
    // libretro's interface callbacks. `handle` is `this`.
    static void SetImage(void *handle, const retro_vulkan_image *image,
                         uint32_t numSemaphores, const VkSemaphore *semaphores,
                         uint32_t srcQueueFamily);
    static uint32_t GetSyncIndex(void *handle);
    static uint32_t GetSyncIndexMask(void *handle);
    static void SetCommandBuffers(void *handle, uint32_t numCommands, const VkCommandBuffer *commands);
    static void WaitSyncIndex(void *handle);
    static void LockQueue(void *handle);
    static void UnlockQueue(void *handle);
    static void SetSignalSemaphore(void *handle, VkSemaphore semaphore);

    bool createReadbackResources(unsigned maxWidth, unsigned maxHeight);
    bool gpuSupportsParallelRDP(VkPhysicalDevice gpu) const;
    int32_t findMemoryType(uint32_t typeBits, VkMemoryPropertyFlags required, VkMemoryPropertyFlags preferred) const;

    VkInstance _instance = VK_NULL_HANDLE;
    VkPhysicalDevice _gpu = VK_NULL_HANDLE;
    VkDevice _device = VK_NULL_HANDLE;
    VkQueue _queue = VK_NULL_HANDLE;
    uint32_t _queueFamily = 0;
    retro_vulkan_destroy_device_t _coreDestroyDevice = nullptr;
    /// Set when the GPU failed to finish a readback in time. The command buffer
    /// may then still be executing, so it is never reused: the picture stops
    /// updating (and the log says why) rather than the app faulting on a
    /// command buffer the GPU still holds.
    bool _readbackLost = false;

    VkCommandPool _commandPool = VK_NULL_HANDLE;
    VkCommandBuffer _commandBuffer = VK_NULL_HANDLE;
    VkFence _fence = VK_NULL_HANDLE;
    VkBuffer _readbackBuffer = VK_NULL_HANDLE;
    VkDeviceMemory _readbackMemory = VK_NULL_HANDLE;
    void *_readbackMapped = nullptr;
    bool _readbackCoherent = false;
    unsigned _maxWidth = 0;
    unsigned _maxHeight = 0;

    retro_hw_render_interface_vulkan _interface = {};

    /// The sync index the core is using this frame, 0 or 1. Flipped by
    /// `beginFrame`, on the thread that is about to enter the core.
    uint32_t _syncIndex = 0;

    /// The core submits from its own worker threads as well as ours, and a
    /// VkQueue must not be used from two threads at once. `lock_queue` /
    /// `unlock_queue` are how the core takes this; `readFrame` takes it too.
    std::mutex _queueLock;

    /// What `set_image` last named, and what it asked us to wait on or signal.
    /// Only touched on the emulation thread (set_image and the readback both run
    /// inside or right after `retro_run`).
    retro_vulkan_image _image = {};
    bool _hasImage = false;
    std::vector<VkSemaphore> _waitSemaphores;
    std::vector<VkCommandBuffer> _pendingCommands;
    VkSemaphore _signalSemaphore = VK_NULL_HANDLE;
};

#endif /* N64VulkanFrontend_h */
