    // RHINE：记录这条计算管线的编译耗时（仅在 RHINE_FFX_CACHE_PROBE=1 时输出）。
    const clock_t rhineCompileStart = rhineProbeEnabled ? clock() : clock_t(0);
    const VkResult rhinePipelineResult = backendContext->vkFunctionTable.vkCreateComputePipelines(backendContext->device, rhineCacheForThisDevice, 1, &pipelineCreateInfo, nullptr, &computePipeline);
    if (rhineProbeEnabled)
    {
        fprintf(stderr, "[ffx-cache] effect=%d pass=%d %.2f ms cache=%s\n", (int)effect, (int)pass,
                1000.0 * double(clock() - rhineCompileStart) / double(CLOCKS_PER_SEC),
                rhineCacheForThisDevice != VK_NULL_HANDLE ? "on" : "off");
    }
    if (rhinePipelineResult != VK_SUCCESS) {