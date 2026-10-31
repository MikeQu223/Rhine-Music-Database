    // RHINE 补丁：给 FFX 的计算管线挂一个进程级 VkPipelineCache。
    //
    // 上游 SDK 1.1.4 在 CreatePipelineVK 里把 pipelineCache 传成 nullptr，整个 Vulkan 后端
    // 没有任何管线缓存。而 FSR3 上下文在窗口尺寸或格式变化时会被整体销毁重建
    // （见 Qt/src/fg/FgBackend.cpp 的 resize 路径），重建后每个 pass 都要重新编译一次计算
    // 管线；核显上这一批编译就是用户拖窗口时能看到的卡顿。这里按 VkDevice 复用一个活到
    // 进程结束的缓存，让重建后的编译直接命中。任何一步失败都退回 VK_NULL_HANDLE，等价于
    // 上游原本的行为。
    // RHINE_FFX_PIPELINE_CACHE=0 可以整段关掉这个缓存（A/B 用，行为和上游一致）；
    // RHINE_FFX_CACHE_PROBE=1 会为每条管线打一行编译耗时，便于确认命中效果。
    static const char* rhineCacheEnv = getenv("RHINE_FFX_PIPELINE_CACHE");
    static const bool rhineCacheBypass =
        rhineCacheEnv != nullptr && rhineCacheEnv[0] == '0' && rhineCacheEnv[1] == '\0';
    static const bool rhineProbeEnabled = getenv("RHINE_FFX_CACHE_PROBE") != nullptr;

    static VkPipelineCache rhinePipelineCache = VK_NULL_HANDLE;
    static VkDevice rhinePipelineCacheDevice = VK_NULL_HANDLE;
    if (!rhineCacheBypass &&
        rhinePipelineCache == VK_NULL_HANDLE &&
        rhinePipelineCacheDevice != backendContext->device &&
        backendContext->vkFunctionTable.vkGetDeviceProcAddr != nullptr)
    {
        PFN_vkCreatePipelineCache rhineCreatePipelineCache =
            (PFN_vkCreatePipelineCache)backendContext->vkFunctionTable.vkGetDeviceProcAddr(
                backendContext->device, "vkCreatePipelineCache");
        if (rhineCreatePipelineCache != nullptr)
        {
            VkPipelineCacheCreateInfo rhineCacheInfo = {};
            rhineCacheInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;
            if (rhineCreatePipelineCache(backendContext->device, &rhineCacheInfo, nullptr, &rhinePipelineCache) != VK_SUCCESS)
            {
                rhinePipelineCache = VK_NULL_HANDLE;
            }
            rhinePipelineCacheDevice = backendContext->device;
        }
    }
    // 只有缓存确实属于当前设备时才交给驱动，换设备自动退回上游行为。
    const VkPipelineCache rhineCacheForThisDevice =
        (rhinePipelineCacheDevice == backendContext->device) ? rhinePipelineCache : VK_NULL_HANDLE;
