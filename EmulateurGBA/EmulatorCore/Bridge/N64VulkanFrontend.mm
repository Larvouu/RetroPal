//
//  N64VulkanFrontend.mm
//  EmulateurGBA
//
//  See N64VulkanFrontend.h for what this is and why it copies frames.
//

#if !__has_include(<vulkan/vulkan.h>)
#error "MoltenVK is missing. Run Vendor/moltenvk-ios/build.sh (it needs the Vendor/MoltenVK submodule: git submodule update --init Vendor/MoltenVK)"
#endif

#include "N64VulkanFrontend.h"

#include <cstring>
#include <dispatch/dispatch.h>
#include <os/log.h>

static os_log_t N64VulkanLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.retropal.emulateurgba", "n64-vulkan"); });
    return log;
}

/// How long `readFrame` waits for the GPU before giving the frame up. A frame
/// takes a few milliseconds; a second means the device is lost or wedged, and
/// the emulation thread must not hang on it forever.
static const uint64_t kReadbackTimeoutNs = 1000000000ULL;

N64VulkanFrontend::N64VulkanFrontend() = default;

N64VulkanFrontend::~N64VulkanFrontend() {
    destroy();
}

static bool HasExtension(const std::vector<VkExtensionProperties> &list, const char *name) {
    for (const auto &e : list) {
        if (strcmp(e.extensionName, name) == 0) return true;
    }
    return false;
}

bool N64VulkanFrontend::createInstance() {
    destroy();

    // The core's own application info (get_application_info) only arrives with
    // the negotiation interface, AFTER this runs. What it would say is the
    // Vulkan version it targets, 1.1, which is what is asked for here.
    VkApplicationInfo app = {};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "Retro Pal";
    app.apiVersion = VK_API_VERSION_1_1;

    uint32_t extensionCount = 0;
    vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr);
    std::vector<VkExtensionProperties> available(extensionCount);
    if (extensionCount) vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, available.data());

    // Both are enabled only if present. The first lets device creation chain
    // the feature structures parallel-RDP asks for; the second is what a
    // Vulkan-on-Metal implementation expects to be told, since it is not a
    // fully conformant Vulkan and says so.
    std::vector<const char *> extensions;
    VkInstanceCreateFlags flags = 0;
    if (HasExtension(available, VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)) {
        extensions.push_back(VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
    }
    if (HasExtension(available, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }

    VkInstanceCreateInfo instanceInfo = {};
    instanceInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instanceInfo.flags = flags;
    instanceInfo.pApplicationInfo = &app;
    instanceInfo.enabledExtensionCount = (uint32_t)extensions.size();
    instanceInfo.ppEnabledExtensionNames = extensions.empty() ? nullptr : extensions.data();

    VkResult result = vkCreateInstance(&instanceInfo, nullptr, &_instance);
    if (result != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkCreateInstance failed (%d)", (int)result);
        _instance = VK_NULL_HANDLE;
        return false;
    }

    uint32_t gpuCount = 0;
    vkEnumeratePhysicalDevices(_instance, &gpuCount, nullptr);
    if (gpuCount == 0) {
        os_log_error(N64VulkanLog(), "no Vulkan device");
        destroy();
        return false;
    }
    // An iPhone or iPad has exactly one GPU.
    std::vector<VkPhysicalDevice> gpus(gpuCount);
    vkEnumeratePhysicalDevices(_instance, &gpuCount, gpus.data());
    _gpu = gpus[0];

    if (!gpuSupportsParallelRDP(_gpu)) {
        destroy();
        return false;
    }
    return true;
}

bool N64VulkanFrontend::gpuSupportsParallelRDP(VkPhysicalDevice gpu) const {
    VkPhysicalDeviceProperties properties = {};
    vkGetPhysicalDeviceProperties(gpu, &properties);
    if (properties.apiVersion < VK_API_VERSION_1_1) {
        os_log_error(N64VulkanLog(), "this GPU offers Vulkan %u.%u; parallel-RDP needs 1.1",
                     VK_API_VERSION_MAJOR(properties.apiVersion), VK_API_VERSION_MINOR(properties.apiVersion));
        return false;
    }

    // The two features parallel-RDP refuses to start without
    // (rdp_renderer.cpp, "a minimum requirement for paraLLEl-RDP").
    VkPhysicalDevice8BitStorageFeatures storage8 = {};
    storage8.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_8BIT_STORAGE_FEATURES;
    VkPhysicalDevice16BitStorageFeatures storage16 = {};
    storage16.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES;
    storage16.pNext = &storage8;
    VkPhysicalDeviceFeatures2 features = {};
    features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features.pNext = &storage16;
    vkGetPhysicalDeviceFeatures2(gpu, &features);

    if (!storage16.storageBuffer16BitAccess || !storage8.storageBuffer8BitAccess) {
        os_log_error(N64VulkanLog(), "this GPU lacks %{public}s%{public}s%{public}s storage-buffer access, "
                     "which parallel-RDP requires",
                     storage8.storageBuffer8BitAccess ? "" : "8-bit",
                     (!storage8.storageBuffer8BitAccess && !storage16.storageBuffer16BitAccess) ? " and " : "",
                     storage16.storageBuffer16BitAccess ? "" : "16-bit");
        return false;
    }
    return true;
}

bool N64VulkanFrontend::createDevice(const retro_hw_render_context_negotiation_interface_vulkan *negotiation,
                                     unsigned maxWidth, unsigned maxHeight) {
    if (_instance == VK_NULL_HANDLE || _gpu == VK_NULL_HANDLE) {
        os_log_error(N64VulkanLog(), "device requested before the instance");
        return false;
    }
    if (!negotiation || !negotiation->create_device) {
        // parallel-RDP always offers one. Without it we would have to guess
        // the device features it needs, and a wrong guess renders nothing.
        os_log_error(N64VulkanLog(), "the core offered no device negotiation; refusing to guess its device");
        return false;
    }

    // No extensions, layers or features of our own: the core asks for what
    // parallel-RDP needs itself. The features are passed as an all-false set
    // and NOT as nullptr, which libretro_vulkan.h does not say is allowed and
    // which parallel-RDP dereferences unconditionally (Context::create_device
    // copies *required_features before adding its own).
    const VkPhysicalDeviceFeatures noRequiredFeatures = {};
    retro_vulkan_context context = {};
    const bool created = negotiation->create_device(&context, _instance, _gpu, VK_NULL_HANDLE,
                                                    vkGetInstanceProcAddr,
                                                    nullptr, 0, nullptr, 0, &noRequiredFeatures);
    if (!created || context.device == VK_NULL_HANDLE) {
        os_log_error(N64VulkanLog(), "the core could not create its Vulkan device");
        return false;
    }
    _gpu = context.gpu;
    _device = context.device;
    _queue = context.queue;
    _queueFamily = context.queue_family_index;
    _coreDestroyDevice = negotiation->destroy_device;

    if (!createReadbackResources(maxWidth, maxHeight)) {
        return false;
    }

    // --- the interface the core will ask for ---------------------------------

    _interface = {};
    _interface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    _interface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    _interface.handle = this;
    _interface.instance = _instance;
    _interface.gpu = _gpu;
    _interface.device = _device;
    _interface.get_device_proc_addr = vkGetDeviceProcAddr;
    _interface.get_instance_proc_addr = vkGetInstanceProcAddr;
    _interface.queue = _queue;
    // libretro calls this an index; it is the queue FAMILY index, which is how
    // every frontend fills it and what the core passes on to its barriers.
    _interface.queue_index = _queueFamily;
    _interface.set_image = SetImage;
    _interface.get_sync_index = GetSyncIndex;
    _interface.get_sync_index_mask = GetSyncIndexMask;
    _interface.set_command_buffers = SetCommandBuffers;
    _interface.wait_sync_index = WaitSyncIndex;
    _interface.lock_queue = LockQueue;
    _interface.unlock_queue = UnlockQueue;
    _interface.set_signal_semaphore = SetSignalSemaphore;
    return true;
}

bool N64VulkanFrontend::createReadbackResources(unsigned maxWidth, unsigned maxHeight) {
    _maxWidth = maxWidth;
    _maxHeight = maxHeight;

    VkCommandPoolCreateInfo poolInfo = {};
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    poolInfo.queueFamilyIndex = _queueFamily;
    if (vkCreateCommandPool(_device, &poolInfo, nullptr, &_commandPool) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkCreateCommandPool failed");
        _commandPool = VK_NULL_HANDLE;
        return false;
    }

    VkCommandBufferAllocateInfo allocInfo = {};
    allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocInfo.commandPool = _commandPool;
    allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocInfo.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(_device, &allocInfo, &_commandBuffer) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkAllocateCommandBuffers failed");
        _commandBuffer = VK_NULL_HANDLE;
        return false;
    }

    VkFenceCreateInfo fenceInfo = {};
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (vkCreateFence(_device, &fenceInfo, nullptr, &_fence) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkCreateFence failed");
        _fence = VK_NULL_HANDLE;
        return false;
    }

    VkBufferCreateInfo bufferInfo = {};
    bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferInfo.size = (VkDeviceSize)maxWidth * maxHeight * 4;
    bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(_device, &bufferInfo, nullptr, &_readbackBuffer) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkCreateBuffer failed");
        _readbackBuffer = VK_NULL_HANDLE;
        return false;
    }

    VkMemoryRequirements requirements = {};
    vkGetBufferMemoryRequirements(_device, _readbackBuffer, &requirements);
    // Host-visible is required. Cached is preferred because the CPU READS this
    // memory every frame, and reading uncached memory is many times slower.
    const int32_t type = findMemoryType(requirements.memoryTypeBits,
                                        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                                        VK_MEMORY_PROPERTY_HOST_CACHED_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (type < 0) {
        os_log_error(N64VulkanLog(), "no host-visible memory for the frame readback");
        return false;
    }
    VkPhysicalDeviceMemoryProperties memoryProperties = {};
    vkGetPhysicalDeviceMemoryProperties(_gpu, &memoryProperties);
    _readbackCoherent = (memoryProperties.memoryTypes[type].propertyFlags
                         & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;

    VkMemoryAllocateInfo memoryInfo = {};
    memoryInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    memoryInfo.allocationSize = requirements.size;
    memoryInfo.memoryTypeIndex = (uint32_t)type;
    if (vkAllocateMemory(_device, &memoryInfo, nullptr, &_readbackMemory) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkAllocateMemory failed for the frame readback");
        _readbackMemory = VK_NULL_HANDLE;
        return false;
    }
    if (vkBindBufferMemory(_device, _readbackBuffer, _readbackMemory, 0) != VK_SUCCESS
        || vkMapMemory(_device, _readbackMemory, 0, VK_WHOLE_SIZE, 0, &_readbackMapped) != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "could not map the frame readback buffer");
        _readbackMapped = nullptr;
        return false;
    }
    return true;
}

int32_t N64VulkanFrontend::findMemoryType(uint32_t typeBits, VkMemoryPropertyFlags required,
                                          VkMemoryPropertyFlags preferred) const {
    VkPhysicalDeviceMemoryProperties properties = {};
    vkGetPhysicalDeviceMemoryProperties(_gpu, &properties);
    int32_t fallback = -1;
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if (!(typeBits & (1u << i))) continue;
        const VkMemoryPropertyFlags flags = properties.memoryTypes[i].propertyFlags;
        if ((flags & required) != required) continue;
        if ((flags & preferred) == preferred) return (int32_t)i;
        if (fallback < 0) fallback = (int32_t)i;
    }
    return fallback;
}

void N64VulkanFrontend::destroy() {
    if (_device != VK_NULL_HANDLE) {
        // Nothing may still be running on the device when its objects go.
        vkDeviceWaitIdle(_device);
        if (_readbackMapped) vkUnmapMemory(_device, _readbackMemory);
        if (_readbackBuffer) vkDestroyBuffer(_device, _readbackBuffer, nullptr);
        if (_readbackMemory) vkFreeMemory(_device, _readbackMemory, nullptr);
        if (_fence) vkDestroyFence(_device, _fence, nullptr);
        if (_commandPool) vkDestroyCommandPool(_device, _commandPool, nullptr);
        // libretro: the core frees its auxiliary resources first, and the
        // device itself belongs to the frontend.
        if (_coreDestroyDevice) _coreDestroyDevice();
        vkDestroyDevice(_device, nullptr);
    }
    if (_instance != VK_NULL_HANDLE) vkDestroyInstance(_instance, nullptr);

    _readbackMapped = nullptr;
    _readbackBuffer = VK_NULL_HANDLE;
    _readbackMemory = VK_NULL_HANDLE;
    _fence = VK_NULL_HANDLE;
    _commandBuffer = VK_NULL_HANDLE;
    _commandPool = VK_NULL_HANDLE;
    _coreDestroyDevice = nullptr;
    _device = VK_NULL_HANDLE;
    _queue = VK_NULL_HANDLE;
    _gpu = VK_NULL_HANDLE;
    _instance = VK_NULL_HANDLE;
    _interface = {};
    _image = {};
    _hasImage = false;
    _readbackLost = false;
    _waitSemaphores.clear();
    _pendingCommands.clear();
    _signalSemaphore = VK_NULL_HANDLE;
}

bool N64VulkanFrontend::readFrame(unsigned width, unsigned height, uint32_t *dst, size_t dstStridePixels) {
    if (_readbackLost || !_hasImage || !_readbackMapped || !dst || width == 0 || height == 0) return false;
    if (width > _maxWidth) width = _maxWidth;
    if (height > _maxHeight) height = _maxHeight;

    const VkImage image = _image.create_info.image;
    const VkImageLayout layout = _image.image_layout;
    VkImageSubresourceRange range = _image.create_info.subresourceRange;
    if (range.aspectMask == 0) range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    if (range.levelCount == 0) range.levelCount = 1;
    if (range.layerCount == 0) range.layerCount = 1;

    vkResetFences(_device, 1, &_fence);
    vkResetCommandBuffer(_commandBuffer, 0);

    VkCommandBufferBeginInfo begin = {};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(_commandBuffer, &begin);

    // The core left the image in `layout` (shader-read) after writing it. Move
    // it to a copy source, waiting for every write before it.
    VkImageMemoryBarrier toTransfer = {};
    toTransfer.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    toTransfer.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    toTransfer.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    toTransfer.oldLayout = layout;
    toTransfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toTransfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toTransfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toTransfer.image = image;
    toTransfer.subresourceRange = range;
    vkCmdPipelineBarrier(_commandBuffer,
                         VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &toTransfer);

    VkBufferImageCopy region = {};
    region.bufferOffset = 0;
    region.bufferRowLength = 0;      // tightly packed: `width` pixels per row
    region.bufferImageHeight = 0;
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.mipLevel = range.baseMipLevel;
    region.imageSubresource.baseArrayLayer = range.baseArrayLayer;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = { width, height, 1 };
    vkCmdCopyImageToBuffer(_commandBuffer, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           _readbackBuffer, 1, &region);

    // Hand the image back in the layout the core left it in; the core will
    // transition it again from there on its next frame.
    VkImageMemoryBarrier toOriginal = toTransfer;
    toOriginal.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    toOriginal.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
    toOriginal.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toOriginal.newLayout = layout;
    // And make the copied bytes visible to the CPU.
    VkBufferMemoryBarrier toHost = {};
    toHost.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    toHost.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toHost.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
    toHost.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toHost.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toHost.buffer = _readbackBuffer;
    toHost.offset = 0;
    toHost.size = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(_commandBuffer,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, nullptr, 1, &toHost, 1, &toOriginal);

    vkEndCommandBuffer(_commandBuffer);

    // Anything the core asked us to submit for it goes first, then our copy.
    std::vector<VkCommandBuffer> commands = _pendingCommands;
    commands.push_back(_commandBuffer);
    std::vector<VkPipelineStageFlags> waitStages(_waitSemaphores.size(), VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);

    VkSubmitInfo submit = {};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = (uint32_t)_waitSemaphores.size();
    submit.pWaitSemaphores = _waitSemaphores.empty() ? nullptr : _waitSemaphores.data();
    submit.pWaitDstStageMask = waitStages.empty() ? nullptr : waitStages.data();
    submit.commandBufferCount = (uint32_t)commands.size();
    submit.pCommandBuffers = commands.data();
    submit.signalSemaphoreCount = _signalSemaphore != VK_NULL_HANDLE ? 1 : 0;
    submit.pSignalSemaphores = _signalSemaphore != VK_NULL_HANDLE ? &_signalSemaphore : nullptr;

    VkResult result;
    {
        std::lock_guard<std::mutex> lock(_queueLock);
        result = vkQueueSubmit(_queue, 1, &submit, _fence);
    }
    // libretro: semaphores and command buffers given for a frame are used once.
    _waitSemaphores.clear();
    _pendingCommands.clear();
    _signalSemaphore = VK_NULL_HANDLE;
    if (result != VK_SUCCESS) {
        os_log_error(N64VulkanLog(), "vkQueueSubmit failed for the frame readback (%d)", (int)result);
        return false;
    }

    result = vkWaitForFences(_device, 1, &_fence, VK_TRUE, kReadbackTimeoutNs);
    if (result != VK_SUCCESS) {
        _readbackLost = true;
        os_log_error(N64VulkanLog(), "the GPU did not finish a frame within a second (%d); "
                     "the picture stops updating for this session", (int)result);
        return false;
    }

    if (!_readbackCoherent) {
        VkMappedMemoryRange mapped = {};
        mapped.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        mapped.memory = _readbackMemory;
        mapped.offset = 0;
        mapped.size = VK_WHOLE_SIZE;
        vkInvalidateMappedMemoryRanges(_device, 1, &mapped);
    }

    const uint8_t *src = (const uint8_t *)_readbackMapped;
    const size_t rowBytes = (size_t)width * 4;
    for (unsigned y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * dstStridePixels, src + (size_t)y * rowBytes, rowBytes);
    }
    return true;
}

// MARK: - libretro interface callbacks

void N64VulkanFrontend::SetImage(void *handle, const retro_vulkan_image *image,
                                 uint32_t numSemaphores, const VkSemaphore *semaphores,
                                 uint32_t srcQueueFamily) {
    auto *self = (N64VulkanFrontend *)handle;
    if (!self) return;
    if (!image) {
        self->_hasImage = false;
        return;
    }
    self->_image = *image;
    self->_hasImage = true;
    // `srcQueueFamily` asks for an ownership transfer when the core rendered on
    // another queue family. It renders on the one queue we gave it, and passes
    // VK_QUEUE_FAMILY_IGNORED, so there is nothing to transfer.
    (void)srcQueueFamily;
    self->_waitSemaphores.assign(semaphores, semaphores + numSemaphores);
}

/// TWO sync indices, and why not one.
///
/// parallel-RDP keeps one Granite frame context per sync index, and frees a
/// context's leftovers (the scanout's temporary images, among others) when it
/// next enters that context, after waiting on its own timeline semaphore. With
/// one index that happens at the end of the very frame that used them.
///
/// On MoltenVK that wait is not enough. MoltenVK submits with UNRETAINED Metal
/// command buffers (MVKQueue.mm, `getActiveMTLCommandBuffer`), and a timeline
/// wait returns as soon as the GPU signals the semaphore, before Metal has
/// marked the command buffer complete (the same gap as MoltenVK PR #2839).
/// Freeing in that gap breaks Metal's rule that an unretained command
/// buffer's resources outlive it; Metal API validation stopped on exactly that
/// on the first Ocarina of Time run (a 325x239 scanout texture).
///
/// With two indices a frame's leftovers are freed at the end of the FOLLOWING
/// frame, and `beginFrame` drains the queue before every frame: so by the time
/// anything is freed, every Metal command buffer that used it has completed.
uint32_t N64VulkanFrontend::GetSyncIndex(void *handle) {
    auto *self = (N64VulkanFrontend *)handle;
    return self ? self->_syncIndex : 0;
}
uint32_t N64VulkanFrontend::GetSyncIndexMask(void *) { return 0x3; }

/// This core never calls it (its `parallel_begin_frame`, the only caller, is
/// never called); `beginFrame` does the waiting instead, from the bridge. Kept
/// correct anyway in case a later core does call it.
void N64VulkanFrontend::WaitSyncIndex(void *handle) {
    auto *self = (N64VulkanFrontend *)handle;
    if (self) self->drainQueue();
}

void N64VulkanFrontend::drainQueue() {
    if (_queue == VK_NULL_HANDLE) return;
    // MoltenVK's vkQueueWaitIdle commits a fresh Metal command buffer and waits
    // until it COMPLETES. Metal completes a queue's command buffers in order,
    // so every earlier one has completed too, which is the guarantee the
    // timeline wait does not give.
    std::lock_guard<std::mutex> lock(_queueLock);
    vkQueueWaitIdle(_queue);
}

void N64VulkanFrontend::beginFrame() {
    if (_device == VK_NULL_HANDLE) return;
    drainQueue();
    _syncIndex ^= 1u;
}

void N64VulkanFrontend::SetCommandBuffers(void *handle, uint32_t numCommands, const VkCommandBuffer *commands) {
    auto *self = (N64VulkanFrontend *)handle;
    if (!self || !commands) return;
    self->_pendingCommands.assign(commands, commands + numCommands);
}

void N64VulkanFrontend::LockQueue(void *handle) {
    auto *self = (N64VulkanFrontend *)handle;
    if (self) self->_queueLock.lock();
}

void N64VulkanFrontend::UnlockQueue(void *handle) {
    auto *self = (N64VulkanFrontend *)handle;
    if (self) self->_queueLock.unlock();
}

void N64VulkanFrontend::SetSignalSemaphore(void *handle, VkSemaphore semaphore) {
    auto *self = (N64VulkanFrontend *)handle;
    if (self) self->_signalSemaphore = semaphore;
}
