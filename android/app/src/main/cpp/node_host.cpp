// Flutter 侧 Node 运行时宿主：把 libnode.so 的 node::Start 拉起来跑 MusicBridge 的
// ios-runtime.cjs。契约照抄 Qt/src/BridgeProcessAndroid.cpp:96-152：
//  - argv 是同一块可写缓冲里的 4 段 NUL 分隔串（"node\0" script "\0" port "\0" token "\0"）；
//  - 线程栈必须 8 MiB（Android 默认 1 MB 会直接爆栈）；
//  - launch 幂等：已启动时不再第二次 node::Start。
#include <jni.h>

#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdlib.h>
#include <unistd.h>

namespace {

constexpr const char *kTag = "RhineNodeHost";


struct StartArgs {
    char *buffer;   // 4 段 NUL 分隔串 + 收尾 NUL
    char **argv;    // 指向 buffer 内的 4 个位置
    int argc;
};

bool g_started = false;

void *threadMain(void *raw) {
    StartArgs *args = static_cast<StartArgs *>(raw);
    void *handle = dlopen("libnode.so", RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "dlopen libnode.so failed: %s", dlerror());
        delete[] args->argv;
        free(args->buffer);
        delete args;
        return nullptr;
    }
    using NodeStart = int (*)(int, char **);
    auto start = reinterpret_cast<NodeStart>(dlsym(handle, "_ZN4node5StartEiPPc"));
    if (start == nullptr) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "dlsym node::Start failed: %s", dlerror());
        dlclose(handle);
        delete[] args->argv;
        free(args->buffer);
        delete args;
        return nullptr;
    }
    __android_log_print(ANDROID_LOG_INFO, kTag, "node::Start(%d) on worker thread", args->argc);
    const int code = start(args->argc, args->argv);
    __android_log_print(ANDROID_LOG_INFO, kTag, "node::Start returned %d", code);
    // argv 必须活过 node::Start 全程；返回后由这里统一释放。
    delete[] args->argv;
    free(args->buffer);
    delete args;
    return nullptr;
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_rhine_music_database_porting_NodeHost_startNode(JNIEnv *env, jclass, jstring script,
                                                     jint port, jstring token, jstring cwd) {
    if (g_started) {
        return JNI_TRUE;  // 幂等：Qt 的 launch 也只有 launched 一个闸门。
    }
    const char *scriptChars = env->GetStringUTFChars(script, nullptr);
    const char *tokenChars = env->GetStringUTFChars(token, nullptr);
    const char *cwdChars = env->GetStringUTFChars(cwd, nullptr);
    if (scriptChars == nullptr || tokenChars == nullptr || cwdChars == nullptr) {
        return JNI_FALSE;
    }
    char portText[8];
    snprintf(portText, sizeof(portText), "%d", static_cast<int>(port));

    const size_t length = std::strlen("node") + 1 + std::strlen(scriptChars) + 1 +
                          std::strlen(portText) + 1 + std::strlen(tokenChars) + 1;
    char *buffer = static_cast<char *>(std::calloc(length + 1, 1));
    if (buffer == nullptr) {
        env->ReleaseStringUTFChars(script, scriptChars);
        env->ReleaseStringUTFChars(token, tokenChars);
        env->ReleaseStringUTFChars(cwd, cwdChars);
        return JNI_FALSE;
    }
    char **argv = new char *[4];
    size_t offset = 0;
    const char *parts[4] = {"node", scriptChars, portText, tokenChars};
    for (int index = 0; index < 4; ++index) {
        const size_t partLength = std::strlen(parts[index]);
        std::memcpy(buffer + offset, parts[index], partLength);
        argv[index] = buffer + offset;
        offset += partLength + 1;  // 逐段留 NUL
    }

    env->ReleaseStringUTFChars(script, scriptChars);
    env->ReleaseStringUTFChars(token, tokenChars);

    // 工作目录对 worker 解析相对路径有用（Qt 不切，这里跟着切到资源根，保持与
    // `root + "/MusicBridge/worker.cjs"` 的调用方一致）。
    if (chdir(cwdChars) != 0) {
        __android_log_print(ANDROID_LOG_WARN, kTag, "chdir(%s) failed", cwdChars);
    }
    env->ReleaseStringUTFChars(cwd, cwdChars);

    // 进程内 Node 只允许一份：把这个标记摆在 Qt 侧 `BridgeProcessAndroid::launch()` 能看见的
    // 环境里，它就不会再起第二个 `node::Start`（v8 trap handler 二次初始化会 SIGTRAP）。
    setenv("RHINE_NODE_IN_PROCESS", "1", 1);

    auto *args = new StartArgs{buffer, argv, 4};
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    pthread_t thread;
    const int created = pthread_create(&thread, &attributes, threadMain, args);
    pthread_attr_destroy(&attributes);
    if (created != 0) {
        __android_log_print(ANDROID_LOG_ERROR, kTag, "pthread_create failed: %d", created);
        delete[] argv;
        free(buffer);
        delete args;
        return JNI_FALSE;
    }
    pthread_detach(thread);
    g_started = true;
    return JNI_TRUE;
}
