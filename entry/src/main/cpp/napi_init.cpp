#include "napi/native_api.h"
#include <dlfcn.h>
#include <string>
#include <vector>

using StartFunction = int (*)(int, char *, int, char *, char *, int);
using StopFunction = void (*)();
static StartFunction startEngine = nullptr;
static StopFunction stopEngine = nullptr;

static bool LoadEngine(napi_env env)
{
    if (startEngine != nullptr && stopEngine != nullptr) {
        return true;
    }
    void *handle = dlopen("libtungo.so", RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        Dl_info libraryInfo{};
        if (dladdr(reinterpret_cast<void *>(LoadEngine), &libraryInfo) && libraryInfo.dli_fname) {
            std::string path(libraryInfo.dli_fname);
            path = path.substr(0, path.find_last_of('/') + 1) + "libtungo.so";
            handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        }
    }
    if (handle == nullptr) {
        const char *error = dlerror();
        napi_throw_error(env, nullptr, error ? error : "Cannot load libtungo.so");
        return false;
    }
    startEngine = reinterpret_cast<StartFunction>(dlsym(handle, "TunStart"));
    stopEngine = reinterpret_cast<StopFunction>(dlsym(handle, "TunStop"));
    if (startEngine == nullptr || stopEngine == nullptr) {
        napi_throw_error(env, nullptr, "Missing TunStart/TunStop; rebuild libtungo.so");
        return false;
    }
    return true;
}

static bool ReadString(napi_env env, napi_value value, std::vector<char> &buffer)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    buffer.resize(length + 1);
    return napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) == napi_ok;
}

static napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    int32_t port = 0;
    std::vector<char> host;
    std::vector<char> logPath;
    if (argc != 4 || napi_get_value_int32(env, args[0], &fd) != napi_ok ||
        !ReadString(env, args[1], host) || napi_get_value_int32(env, args[2], &port) != napi_ok ||
        !ReadString(env, args[3], logPath)) {
        napi_throw_type_error(env, nullptr, "Expected fd, host, port, logPath");
        return nullptr;
    }
    if (!LoadEngine(env)) {
        return nullptr;
    }
    char error[512] = {0};
    if (startEngine(fd, host.data(), port, logPath.data(), error, sizeof(error)) != 0) {
        napi_throw_error(env, nullptr, error);
        return nullptr;
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Stop(napi_env env, napi_callback_info info)
{
    if (stopEngine != nullptr) {
        stopEngine();
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "startTun2Socks", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopTun2Socks", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module entryModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&entryModule);
}
