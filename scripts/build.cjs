// 同一资源与构建流程；平台分支仅处理 Qt 部署和系统签名。
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { app: defaultAppPath, resourceDirectory } = require('./app-layout.cjs');
const { buildVersion, packageIdentity } = require('./release-version.cjs');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
process.chdir(root);
const win = process.platform === 'win32';
const mac = process.platform === 'darwin';
const linux = process.platform === 'linux';
if (!win && !mac && !linux) {
    throw Error('Supported platforms: macOS, Linux and Windows');
}
const python = process.env.PYTHON || (win ? 'python' : 'python3');
const nodeName = win ? 'node.exe' : 'node';
// core-only 产物不打包任何第三方平台插件，干净安装默认不带插件；需要时显式 --plugins=full。
const flavor = process.argv.slice(2).find((value) => value.startsWith('--plugins=')) || '--plugins=core';
const flavorValue = flavor.slice('--plugins='.length);
let pluginIds = null;
if (flavorValue === 'core') {
    pluginIds = [];
} else if (flavorValue !== 'full') {
    pluginIds = flavorValue
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean);
}
if (flavorValue !== 'full' && flavorValue !== 'core' && !pluginIds.length) {
    throw new Error('Unknown plugin flavor: ' + flavor);
}
const pluginsEnabled = pluginIds === null || pluginIds.length > 0;
/**
 * 串行执行构建或部署命令，失败立即终止。
 * 命令和参数分开传递，不经过 Shell 解释。
 */
function run(command, args = [], env = {}) {
    const result = spawnSync(command, args, {
        stdio: 'inherit',
        env: {
            ...process.env,
            ...env,
        },
        shell: false,
    });
    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        throw Error(`${command} exited with ${result.status}`);
    }
}

/** 读取实际执行的 npm 版本，用于判断新版本才有的安全开关。 */
function npmVersion() {
    const cli = process.env.npm_execpath;
    const result = spawnSync(cli ? process.execPath : 'npm', cli ? [cli, '--version'] : ['--version'], {
        encoding: 'utf8',
    });
    return result.status === 0 ? result.stdout.trim() : '';
}

/**
 * npm 11.6 起默认拒绝安装 remote 类型的依赖，而部分插件锁定的上游 SDK 正是 codeload tarball。
 * 只对声明在根 package.json 的远程来源放行，旧版 npm 不传该参数。
 */
function npmRemoteArgs() {
    const [major, minor] = npmVersion().split('.').map(Number);
    return major > 11 || (major === 11 && minor >= 6) ? ['--allow-remote=root'] : [];
}

function npmCi(folder) {
    run(process.execPath, [
        process.env.npm_execpath,
        'ci',
        '--prefix',
        folder,
        '--omit=dev',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        ...npmRemoteArgs(),
    ]);
}
/**
 * 准备字体、模型、锁定桥接依赖和运行时资源；保持原有导出与检查顺序。
 */
function prepareResources() {
    fs.mkdirSync('output', {
        recursive: true,
    });
    run(python, ['scripts/check-qt-project.py']);
    run(python, ['scripts/export-assets.py']);
    run(python, ['scripts/bake-archive-lighting.py']);
    for (const file of fs.readdirSync('Assets/fonts')) {
        fs.copyFileSync(path.join('Assets/fonts', file), path.join('output/resources', file));
    }

    run(process.execPath, ['scripts/check-music-upstream.cjs']);
    const bridge = 'output/resources/MusicBridge';
    fs.mkdirSync(bridge, {
        recursive: true,
    });
    // 只保留依赖缓存，清除已删除的旧源码和资源。
    for (const name of fs.readdirSync(bridge)) {
        if (name !== 'node_modules') {
            fs.rmSync(path.join(bridge, name), { recursive: true, force: true });
        }
    }
    for (const file of [
        'worker.cjs',
        'ios-runtime.cjs',
        'ios-web-apis.cjs',
        'ios-system-trust.cjs',
        'android-web-apis.cjs',
        'lyrics-format.cjs',
        'lyrics-text.cjs',
        'lyrics-source.json',
        'LyricsKit-LICENSE',
        'package.json',
        'package-lock.json',
    ]) {
        fs.copyFileSync(path.join('MusicBridge', file), path.join(bridge, file));
    }
    fs.cpSync('MusicBridge/client', path.join(bridge, 'client'), {
        recursive: true,
    });
    fs.cpSync('MusicBridge/core', path.join(bridge, 'core'), {
        recursive: true,
    });
    fs.cpSync('MusicBridge/plugins', path.join(bridge, 'plugins'), {
        recursive: true,
    });
    if (pluginsEnabled && fs.existsSync('MusicBridge/local-plugins')) {
        const selection = pluginIds ? pluginIds.join(',') : '';
        run(process.execPath, [
            'scripts/bundle-plugins.cjs',
            'MusicBridge/local-plugins',
            ...(selection ? [selection] : []),
        ]);
        if (pluginIds) {
            for (const id of [...pluginIds, 'data', 'modules']) {
                const source = path.join('MusicBridge/local-plugins', id);
                if (fs.existsSync(source)) {
                    fs.cpSync(source, path.join(bridge, 'local-plugins', id), {
                        recursive: true,
                        filter: (file) => !file.split(path.sep).includes('node_modules'),
                    });
                }
            }
        } else {
            fs.cpSync('MusicBridge/local-plugins', path.join(bridge, 'local-plugins'), {
                recursive: true,
                filter: (source) => !source.split(path.sep).includes('node_modules'),
            });
        }
        // Qt 在桥启动前读取 descriptor；构建期从 manifest 提取，避免把入口/签名配置带进 UI。
        run(process.execPath, [
            'scripts/export-descriptors.cjs',
            'MusicBridge/local-plugins',
            path.join(bridge, 'plugins/descriptors'),
            ...(selection ? [selection] : []),
        ]);
    }
    // package lock 变更时重新安装依赖，避免旧版本残留
    const dependencyHash = createHash('sha256')
        .update(fs.readFileSync(path.join(bridge, 'package.json')))
        .update(fs.readFileSync(path.join(bridge, 'package-lock.json')))
        .digest('hex');
    const stamp = path.join(bridge, 'node_modules', '.rhine-lock.sha256');
    const installedHash = fs.existsSync(stamp) ? fs.readFileSync(stamp, 'utf8') : '';
    if (installedHash !== dependencyHash) {
        npmCi(bridge);
        fs.writeFileSync(stamp, dependencyHash);
    }
    // Android 随包的是 libnode.so（进程内运行时），没有独立 node 可执行文件，
    // 也就不需要满足"必须是官方独立分发包"的约束；桥接 bundle 由 build-android.cjs 自己打。
    if (process.env.RHINE_ANDROID_BUILD === '1') {
        return;
    }
    const binary =
        process.env.RHINE_NODE_BINARY ||
        (mac && process.arch === 'arm64' ? path.resolve('vendor/node-arm64/node') : process.execPath);
    // 官方独立分发包把 LICENSE 放在 bin 的上一级；两种解压布局都要能识别。
    const license =
        process.env.RHINE_NODE_LICENSE ||
        [path.join(path.dirname(binary), 'LICENSE'), path.resolve(path.dirname(binary), '../LICENSE')].find(
            (candidate) => fs.existsSync(candidate),
        );
    if (!fs.existsSync(binary) || !license) {
        throw Error(
            'Provide RHINE_NODE_BINARY and its matching RHINE_NODE_LICENSE (official standalone distribution)',
        );
    }
    if (mac) {
        const deps = spawnSync('otool', ['-L', binary], {
            encoding: 'utf8',
        });
        if (
            deps.status !== 0 ||
            /\/opt\/|\/Users\/|@rpath/.test(deps.stdout.split('\n').slice(1).join('\n'))
        ) {
            throw Error('Node must be an official standalone distribution');
        }
    }
    if (linux) {
        // 发行版自带的 node 链接了系统 ICU 与 absl，只有官方静态包能随 AppImage 分发。
        const deps = spawnSync('ldd', [binary], {
            encoding: 'utf8',
        });
        if (deps.status !== 0) {
            throw Error('Node must be an official standalone distribution');
        }
        // 官方静态包只依赖 glibc 与 GCC 运行库；出现其他动态依赖说明用的是发行版构建。
        // 部分官方构建会额外链接 libatomic（GCC 运行时自带的原子操作库）。
        const exposed = deps.stdout
            .split('\n')
            .filter((line) => line.includes('=>'))
            .map((line) => path.basename(line.split('=>')[0].trim()))
            .filter(
                (name) =>
                    !/^(?:ld-linux[\w.-]*|libc|libm|libmvec|libdl|libpthread|librt|libgcc_s|libstdc\+\+|libatomic)\.so/.test(
                        name,
                    ),
            );
        if (exposed.length) {
            throw Error(`Node must be an official standalone distribution: ${exposed.join(', ')}`);
        }
    }
    fs.copyFileSync(binary, path.join(bridge, nodeName));
    fs.copyFileSync(license, path.join(bridge, 'NODE-LICENSE'));
    fs.chmodSync(path.join(bridge, nodeName), 0o755);
    // 桥接在部署前打成单文件
    run(process.execPath, ['scripts/bundle-bridge.cjs']);
    // 同步清理旧暂存文件，开发运行与发布包使用相同的纯原生资源。
    for (const name of [
        'room-pmrem.bin',
        'dfg-lut.bin',
        'ao-kernel.bin',
        'ao-noise.bin',
        'runtime.js',
        'timeline.js',
        'qt-logic.js',
        'archive-cassette-geometry.json',
        'archive-assembly-geometry.json',
    ]) {
        fs.rmSync(path.join('output/resources', name), { force: true });
    }
}
/**
 * 验证 Qt kit 后串行配置和编译，返回部署所需的路径与构建类型。
 */
function buildQt() {
    if (win || mac) {
        run(process.execPath, ['scripts/prepare-crash-tools.cjs']);
    }
    // Linux 的 Qt 通常由发行版装在 /usr，其余平台从 kit 目录读取。
    const qtRoots = new Map([
        [true, path.join(os.homedir(), 'Qt/6.12.0/macos')],
        [false, linux ? '/usr' : ''],
    ]);
    const qt = process.env.QT_ROOT || qtRoots.get(mac);
    if (!qt || !fs.existsSync(path.join(qt, 'lib/cmake/Qt6/Qt6Config.cmake'))) {
        throw Error('Set QT_ROOT to a Qt desktop kit with Shader Tools and private headers');
    }
    const config = process.env.RHINE_BUILD_TYPE || 'Release';
    const version = buildVersion();
    const configure = [
        '-S',
        '.',
        '-B',
        'output/qt-build',
        '-G',
        'Ninja',
        `-DCMAKE_PREFIX_PATH=${qt}`,
        `-DCMAKE_BUILD_TYPE=${config}`,
        '-DRHINE_PACKAGE_APP=OFF',
        `-DRHINE_VERSION=${version.version}`,
        `-DRHINE_RELEASE_BUILD=${version.release ? 'ON' : 'OFF'}`,
    ];
    if (win || mac) {
        // CMake 生成符号时使用当前运行的 Node，避免依赖 PATH 里的系统安装。
        configure.push(`-DRHINE_CRASH_NODE=${process.execPath}`);
    }
    run('cmake', configure);
    run('cmake', ['--build', 'output/qt-build']);
    if (win || mac) {
        // 符号生成只在打包流程执行一次，避免每次增量链接都重跑 dsymutil/dump_syms。
        run('cmake', ['--build', 'output/qt-build', '--target', 'RhineCrashSymbols']);
    }
    return {
        qt,
        config,
    };
}
/**
 * MSVC 运行库部署
 * 仅从当前开发环境的可分发目录取 DLL；缺少运行库时禁止生成不完整的发布包。
 */
function deployWindowsRuntime(app, config) {
    let redist = process.env.VCToolsRedistDir;
    if (!redist) {
        const base = path.join(process.env.VCINSTALLDIR || '', 'Redist/MSVC');
        if (!fs.existsSync(base)) {
            throw new Error('MSVC redist directory missing; build in a Visual Studio developer shell');
        }
        const versions = fs.readdirSync(base).filter((name) => /^\d+\.\d+\.\d+$/.test(name));
        versions.sort((first, second) => second.localeCompare(first, undefined, { numeric: true }));
        if (!versions.length) {
            throw new Error('MSVC redistributable runtime missing');
        }
        redist = path.join(base, versions[0]);
    }
    const debug = config === 'Debug';
    const architecture = path.join(redist, ...(debug ? ['debug_nonredist', 'x64'] : ['x64']));
    const directory = fs
        .readdirSync(architecture)
        .find((name) => (debug ? /^Microsoft\.VC\d+\.DebugCRT$/ : /^Microsoft\.VC\d+\.CRT$/).test(name));
    if (!directory) {
        throw new Error('MSVC x64 runtime DLL directory missing');
    }
    const runtime = path.join(architecture, directory);
    const libraries = fs.readdirSync(runtime).filter((name) => name.toLowerCase().endsWith('.dll'));
    const suffix = debug ? 'd.dll' : '.dll';
    for (const name of ['msvcp140' + suffix, 'vcruntime140' + suffix, 'vcruntime140_1' + suffix]) {
        if (!libraries.includes(name)) {
            throw new Error(`MSVC runtime library missing: ${name}`);
        }
    }
    for (const name of libraries) {
        fs.copyFileSync(path.join(runtime, name), path.join(app, name));
    }
}

/**
 * 根据 Qt 插件实际依赖部署 FFmpeg 动态库，避免 Mac 发布包静默回落到原生后端。
 * 只复制当前 kit 中被引用的库，兼容不同 Qt 补丁版本使用的 FFmpeg 主版本。
 */
function deployMacAudioLibraries(qt, app) {
    const frameworks = path.join(app, 'Contents/Frameworks');
    fs.mkdirSync(frameworks, { recursive: true });
    const plugin = path.join(app, 'Contents/PlugIns/multimedia/libffmpegmediaplugin.dylib');
    const pending = [plugin];
    const deployed = new Set();
    while (pending.length) {
        const binary = pending.pop();
        const result = spawnSync('otool', ['-L', binary], { encoding: 'utf8' });
        if (result.status !== 0) {
            throw new Error(`Cannot inspect multimedia dependency: ${binary}`);
        }
        const pattern =
            /@(?:rpath|loader_path)\/(lib(?:avcodec|avformat|avutil|avfilter|avdevice|swresample|swscale)\.\d+(?:\.\d+)*\.dylib)/g;
        for (const match of result.stdout.matchAll(pattern)) {
            const name = match[1];
            if (deployed.has(name)) {
                continue;
            }
            const source = path.join(qt, 'lib', name);
            fs.copyFileSync(source, path.join(frameworks, name));
            deployed.add(name);
            pending.push(source);
        }
    }
    // 插件位于 Contents/PlugIns/multimedia；音频库位于 Contents/Frameworks。
    run('install_name_tool', ['-add_rpath', '@loader_path/../../Frameworks', plugin]);
}

// AppImage 只随包分发 Qt 与音视频运行时；系统图形栈、glibc 与桌面服务留给发行版。
const linuxExcludedLibraries = new Set([
    'ld-linux-x86-64.so.2',
    'libc.so.6',
    'libm.so.6',
    'libmvec.so.1',
    'libdl.so.2',
    'libpthread.so.0',
    'librt.so.1',
    'libresolv.so.2',
    'libutil.so.1',
    'libnsl.so.1',
    'libgcc_s.so.1',
    'libstdc++.so.6',
    'libz.so.1',
    'libbz2.so.1.0',
    'liblzma.so.5',
    'libzstd.so.1',
    'libexpat.so.1',
    'libffi.so.8',
    'libpcre2-8.so.0',
    'libglib-2.0.so.0',
    'libgobject-2.0.so.0',
    'libgio-2.0.so.0',
    'libgmodule-2.0.so.0',
    'libmount.so.1',
    'libblkid.so.1',
    'libselinux.so.1',
    'libsystemd.so.0',
    'libudev.so.1',
    'libdbus-1.so.3',
    'libfontconfig.so.1',
    'libfreetype.so.6',
    'libharfbuzz.so.0',
    'libgraphite2.so.3',
    'libpng16.so.16',
    // 厂商驱动通过 libGLX/libEGL 装载，这两个交给发行版，避免遮蔽专有驱动。
    // libOpenGL 只做厂商中立的 GL 分发，且 Ubuntu 26.04 默认桌面不装 libopengl0，
    // 而 Qt6Gui 直接依赖它，留给系统会在启动前就报缺库，因此随包分发。
    'libGL.so.1',
    'libGLX.so.0',
    'libEGL.so.1',
    'libGLESv2.so.2',
    'libgbm.so.1',
    'libdrm.so.2',
    'libX11.so.6',
    'libX11-xcb.so.1',
    'libXau.so.6',
    'libXdmcp.so.6',
    'libXext.so.6',
    'libXrender.so.1',
    'libXi.so.6',
    'libXfixes.so.3',
    'libXcursor.so.1',
    'libXrandr.so.2',
    'libXinerama.so.1',
    'libXcomposite.so.1',
    'libXdamage.so.1',
    'libxcb.so.1',
    // xkbcommon 本体随发行版；它的 X11 配套库不属于必装集，缺了 X11 插件加载不了键位。
    'libxkbcommon.so.0',
    'libwayland-client.so.0',
    'libwayland-cursor.so.0',
    'libwayland-egl.so.1',
    'libvulkan.so.1',
    'libpulse.so.0',
    'libasound.so.2',
]);
// 图片格式只留窗口与封面真正会用到的几种（png 内置于 QtGui，无需插件）。
// pdf 会经 libopenjp2 → libproxy/libpxbackend/duktape/nghttp2/ngtcp2/krb5 拖进约 10 MB；
// tiff 带入 libtiff/libjbig，tga/icns/wbmp 在桌面 Linux 上不会被遇到。
const linuxImageFormatPlugins = /^libq(?:jpeg|gif|ico|svg|webp)\.so$/;
// xcb 扩展、Wayland 后端与音频服务跟随发行版，版本差异由用户系统统一升级。
// xcb 核心与 XKB 扩展、Wayland 后端与音频服务跟随发行版，版本差异由用户系统统一升级。
// xcb-util 系列（光标、输入法、render-util 等）不在此列：它们只在装有桌面的系统上出现，
// 缺了会让 X11 插件退出，因此随包分发。
const linuxExcludedPattern =
    /^lib(?:wayland-|drm[_-]|vulkan|X11|Xext|Xrender|Xi\.|Xfixes|Xcursor|Xrandr|Xinerama|Xcomposite|Xdamage|Xau|Xdmcp|pulse|asound|nss|nspr|smime|softokn|freebl|plc|plds)/;

function isExcludedLinuxLibrary(name) {
    return linuxExcludedLibraries.has(name) || linuxExcludedPattern.test(name);
}

/**
 * 解析 Qt 运行时的实际位置
 * 不假设 kit 目录结构，直接读取已构建程序解析到的 Qt 库目录。
 */
function linuxQtLibraryDirectory(binary) {
    const result = spawnSync('ldd', [binary], {
        encoding: 'utf8',
    });
    if (result.status !== 0) {
        throw new Error('Cannot inspect Qt runtime dependencies');
    }
    const match = /^\s*libQt6Core\.so\.6 => (\S+) \(0x/m.exec(result.stdout);
    if (!match) {
        throw new Error('Qt6Core is not linked into the executable');
    }
    return path.dirname(match[1]);
}

/**
 * 读取 Qt 安装布局
 * 系统 Qt 的前缀是 /usr，插件和 QML 模块在 /usr/lib/qt6 下，统一由 qmake 给出。
 */
function linuxQtQuery(qt, key) {
    // 官方 Qt 包通常只装 qmake 而没有 qmake6；只要 kit 自带 qmake 就只用它，
    // 否则会把系统 Qt 的路径混进来，导致打包版本与编译版本不一致。
    const kit = [path.join(qt, 'bin/qmake6'), path.join(qt, 'bin/qmake')].filter((file) =>
        fs.existsSync(file),
    );
    const commands = kit.length ? kit : ['qmake6', 'qmake'];
    for (const command of commands) {
        const result = spawnSync(command, ['-query', key], {
            encoding: 'utf8',
        });
        if (result.status === 0 && result.stdout.trim()) {
            return result.stdout.trim();
        }
    }
    throw new Error(`Cannot locate the Qt ${key} directory`);
}

function linuxQtQmlDirectory(qt) {
    return linuxQtQuery(qt, 'QT_INSTALL_QML');
}

/**
 * 定位 Qt 自带工具
 * 优先使用 kit 自己的 bin 目录，避免 PATH 中混入其他 Qt 版本或被裁剪掉的工具。
 */
function linuxQtTool(qt, name) {
    // Qt 6 的工具按发行版不同分散在 libexec 与 bin：官方二进制包放在 libexec，
    // 部分发行版重打包到 /usr/bin。逐个探活，任何可执行的候选都接受。
    const searched = [];
    for (const key of ['QT_INSTALL_LIBEXECS', 'QT_INSTALL_BINS']) {
        let directory;
        try {
            directory = linuxQtQuery(qt, key);
        } catch {
            continue;
        }
        searched.push(path.join(directory, name));
    }
    searched.push(name);
    for (const candidate of searched) {
        // 相对名交给 PATH 解析；绝对路径先确认存在，避免把 qmake 的错误当作成功。
        if (path.isAbsolute(candidate) && !fs.existsSync(candidate)) {
            continue;
        }
        const probe = spawnSync(candidate, ['-help'], {
            encoding: 'utf8',
        });
        // qmlimportscanner 的 -help 也返回非零，能启动即视为可用。
        if (!probe.error) {
            return candidate;
        }
    }
    throw new Error(`Cannot locate the Qt tool ${name}; searched ${searched.join(', ')}`);
}
/**
 * 复制插件、QML 模块与 ELF 依赖闭包
 * 依赖按 ldd 结果递归收集，只跳过系统图形栈与 glibc，避免与用户驱动冲突。
 */
function deployLinuxRuntime(qt, app, binary, ffmpegLibraries = new Map()) {
    const libraries = path.join(app, 'usr/lib');
    const plugins = path.join(app, 'usr/plugins');
    fs.mkdirSync(libraries, {
        recursive: true,
    });
    const qtLibraries = linuxQtLibraryDirectory(binary);
    // 两个进程分别进入依赖闭包，后台服务用到的 Qt 库也必须随包交付。
    const sources = [binary, path.join(path.dirname(binary), 'RhinePlaybackService')];
    const pluginSource = linuxQtQuery(qt, 'QT_INSTALL_PLUGINS');
    // Wayland 平台插件依赖 shell 集成与装饰插件，必须整组跟随部署。
    for (const folder of [
        'platforms',
        'imageformats',
        'tls',
        'multimedia',
        'networkinformation',
        'platforminputcontexts',
        'xcbglintegrations',
        'wayland-shell-integration',
        'wayland-decoration-client',
        'wayland-graphics-integration-client',
    ]) {
        const directory = path.join(pluginSource, folder);
        if (!fs.existsSync(directory)) {
            continue;
        }
        for (const file of fs.readdirSync(directory)) {
            if (!file.endsWith('.so')) {
                continue;
            }
            // 平台插件名随打包方式变化：发行版是 libqwayland.so，
            // 官方 Qt 包拆成 libqwayland-egl.so 与 libqwayland-generic.so。
            if (
                folder === 'platforms' &&
                !/^libq(?:xcb|wayland(?:-\w+)?|offscreen|minimal)\.so$/.test(file)
            ) {
                continue;
            }
            if (folder === 'imageformats' && !linuxImageFormatPlugins.test(file)) {
                continue;
            }
            const destination = path.join(plugins, folder, file);
            fs.mkdirSync(path.dirname(destination), {
                recursive: true,
            });
            fs.copyFileSync(path.join(directory, file), destination);
            sources.push(destination);
        }
    }
    // Wayland 是桌面 Linux 的主流会话；插件缺失时应用会退到 XWayland，
    // 仍能运行但行为不原生。官方 Qt 包把它放在 linux_gcc_64 的附属归档里，
    // 由 aqt 的 --autodesktop 安装，因此这里只提示，不阻断构建。
    const platforms = fs.readdirSync(path.join(plugins, 'platforms'));
    // X11 是 Linux 包的底线：纯 Xorg 会话与 XWayland 都靠它，缺了用户连窗口都没有，
    // 所以这里直接失败，而不是像 Wayland 那样只提示。
    if (!platforms.includes('libqxcb.so')) {
        throw Error('Qt X11 platform plugin missing (platforms/libqxcb.so); the Linux build cannot start');
    }
    // xcb 平台插件不自带 OpenGL 上下文，GLX/EGL 集成缺失时会在初始化 RHI 时退出。
    const xcbGl = path.join(plugins, 'xcbglintegrations');
    const xcbGlPlugins = fs.existsSync(xcbGl) ? fs.readdirSync(xcbGl) : [];
    if (!xcbGlPlugins.some((name) => /^libqxcb-(?:glx|egl)-integration\.so$/.test(name))) {
        console.warn('Qt X11 OpenGL integration missing; X11 sessions will fail to create an RHI context');
    }
    if (!platforms.some((name) => name.startsWith('libqwayland'))) {
        console.warn('Qt Wayland platform plugin missing; Wayland sessions will fall back to XWayland');
    }
    const qmlSource = linuxQtQmlDirectory(qt);
    const scanned = spawnSync(
        linuxQtTool(qt, 'qmlimportscanner'),
        [
            '-rootPath',
            path.join(root, 'Qt/qml'),
            '-importPath',
            qmlSource,
            '-importPath',
            path.join(root, 'Qt/qml'),
        ],
        {
            encoding: 'utf8',
            maxBuffer: 64 * 1024 * 1024,
        },
    );
    if (scanned.status !== 0) {
        // 保留工具自身输出，构建机缺模块时能直接看出缺哪一个。
        const detail = `${scanned.stderr || ''}${scanned.stdout || ''}`
            .trim()
            .split('\n')
            .slice(-5)
            .join('\n');
        throw new Error(`Cannot scan QML imports${detail ? `: ${detail}` : ''}`);
    }
    const modules = new Set();
    for (const entry of JSON.parse(scanned.stdout.replace(/^[^{[]*/, ''))) {
        if (entry.path && entry.path.startsWith(qmlSource + path.sep)) {
            modules.add(path.relative(qmlSource, entry.path));
        }
    }
    for (const module of modules) {
        const destination = path.join(app, 'usr/qml', module);
        fs.cpSync(path.join(qmlSource, module), destination, {
            recursive: true,
        });
        // QML 模块自带的插件同样引用 Qt 库（如 QuickControls2、QuickTemplates2），
        // 只复制文件而不纳入依赖闭包，会留下启动后才暴露的缺库。
        sources.push(...sharedObjects(destination));
    }
    // 插件自身也引用 Qt 与音视频库；与程序一起进入同一个依赖闭包。
    const deployed = new Set();
    // ldd 打印的是完整传递闭包：系统 libavcodec 链接的 x265/aom/SvtAv1Enc 等
    // 虽然没有任何文件直接引用，也会出现在列上。照单全收会把整条编码器链打进包，
    // 因此按 DT_NEEDED 只跟随直接依赖，间接条目由被引用方自己入队后再展开。
    const directNeeded = (file) => {
        const dynamic = spawnSync('readelf', ['-d', file], {
            encoding: 'utf8',
        });
        if (dynamic.status !== 0) {
            // 读不出动态段（非 ELF 或缺少 readelf）时退回闭包，宁大勿缺。
            return null;
        }
        const needed = new Set();
        for (const line of (dynamic.stdout || '').split('\n')) {
            const match = /\(NEEDED\).*\[(\S+)\]/.exec(line);
            if (match) {
                needed.add(match[1]);
            }
        }
        return needed;
    };
    while (sources.length) {
        const source = sources.pop();
        const result = spawnSync('ldd', [source], {
            encoding: 'utf8',
        });
        if (result.status !== 0) {
            continue;
        }
        const direct = directNeeded(source);
        for (const line of result.stdout.split('\n')) {
            const match = /^\s*(\S+) => (\S+) \(0x[0-9a-f]+\)$/.exec(line);
            if (!match) {
                continue;
            }
            let [, name, location] = match;
            // ldd 对解释器给出的是路径而不是 SONAME，这类条目始终由系统提供。
            if (name.includes('/')) {
                continue;
            }
            name = path.basename(name);
            if (direct && !direct.has(name)) {
                continue;
            }
            if (deployed.has(name) || isExcludedLinuxLibrary(name)) {
                continue;
            }
            // 自编的 FFmpeg 不链接发行版的编码器库：用我们的文件替换，
            // 之后按替换后文件的直接依赖继续展开，系统那份的依赖链不再进入队列。
            const replacement = ffmpegLibraries.get(name);
            if (replacement) {
                deployed.add(name);
                const target = path.join(libraries, name);
                fs.copyFileSync(replacement, target);
                fs.chmodSync(target, 0o755);
                sources.push(target);
                continue;
            }
            if (!fs.existsSync(location)) {
                continue;
            }
            deployed.add(name);
            const destination = path.join(libraries, name);
            if (!fs.existsSync(destination)) {
                fs.copyFileSync(location, destination);
                fs.chmodSync(destination, 0o755);
            }
            sources.push(location);
        }
    }
    fs.writeFileSync(
        path.join(app, 'usr/bin/qt.conf'),
        '[Paths]\nPrefix=..\nPlugins=plugins\nQmlImports=qml\n',
    );
}

/**
 * 生成 AppImage
 * 桌面条目、图标与 AppRun 位于 AppDir 根目录，运行库按前缀目录布局。
 */
// 打包工具按官方发行版锁定，构建机不需要预装。
const appImageToolVersion = '1.9.1';
const appImageToolChecksums = {
    x86_64: 'ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0',
    aarch64: '',
};

/**
 * 取得可用的 appimagetool
 * 优先使用 APPIMAGE_TOOL 指定的可执行文件，其次系统 PATH，最后下载锁定版本。
 */
function resolveAppImageTool(architecture) {
    if (process.env.APPIMAGE_TOOL) {
        return process.env.APPIMAGE_TOOL;
    }
    const system = spawnSync('appimagetool', ['--version'], {
        encoding: 'utf8',
    });
    if (!system.error) {
        return 'appimagetool';
    }
    const expected = appImageToolChecksums[architecture];
    if (!expected) {
        throw new Error(
            `Install appimagetool or set APPIMAGE_TOOL for ${architecture}; no pinned checksum is recorded`,
        );
    }
    const directory = path.join('output', 'appimagetool');
    const tool = path.join(directory, `appimagetool-${architecture}.AppImage`);
    if (!fs.existsSync(tool)) {
        fs.mkdirSync(directory, {
            recursive: true,
        });
        const url =
            `https://github.com/AppImage/appimagetool/releases/download/${appImageToolVersion}` +
            `/appimagetool-${architecture}.AppImage`;
        run('curl', ['--fail', '--location', '--retry', '3', '--output', tool, url]);
        const digest = spawnSync('sha256sum', [tool], {
            encoding: 'utf8',
        }).stdout.split(' ')[0];
        if (digest !== expected) {
            fs.rmSync(tool, {
                force: true,
            });
            throw new Error(`appimagetool checksum mismatch: ${digest}`);
        }
        fs.chmodSync(tool, 0o755);
    }
    return tool;
}

/**
 * 下载并校验锁定版本的可执行文件
 * 校验和随版本固定，构建机不需要预装，换版本时必须同步更新。
 */
function downloadPinnedExecutable(directory, name, url, checksum) {
    fs.mkdirSync(directory, {
        recursive: true,
    });
    const file = path.join(directory, name);
    if (!fs.existsSync(file)) {
        run('curl', ['--fail', '--location', '--retry', '3', '--output', file, url]);
        const digest = spawnSync('sha256sum', [file], {
            encoding: 'utf8',
        }).stdout.split(' ')[0];
        if (digest !== checksum) {
            fs.rmSync(file, {
                force: true,
            });
            throw new Error(`${name} checksum mismatch: ${digest}`);
        }
        fs.chmodSync(file, 0o755);
    }
    return file;
}

// DwarFS 打包用到的两个上游工具，同样按版本锁定。
// uruntime 取 -lite 变体：它只内嵌 MIT 许可的 dwarfs 读取器，
// 而完整变体会把 GPL-3.0 的 mkdwarfs 一起塞进运行时。
const uruntimeVersion = 'v0.7.1';
const uruntimeChecksums = {
    x86_64: 'f19d2a58b5f7cb372b8a88b1e9414fd118d8da6d2c555cf3e7c0bac9373b8af9',
    // aarch64: 'bfcb5d2198d675419207345219766182cffa2515754ff813267118277156a07d',
};
const mkdwarfsVersion = '0.15.8';
const mkdwarfsChecksums = {
    x86_64: '0ed66df82f9bb6671c1f898404ff4d57c263460078d46dbac8efb9d8eec271b7',
    // aarch64: 'f21cbc33840bbffe410c7043fab85e0d1b4eee86d77bcc0fbf3a51b94fc4b222',
};

/**
 * 取得可用的 mkdwarfs
 * 优先 MKDWARFS 指定的可执行文件，其次系统 PATH，最后下载锁定的 dwarfs-universal。
 * dwarfs-universal 按 argv[0] 的工具名分派，所以落地文件名必须是 mkdwarfs。
 */
function resolveDwarfsTool(architecture) {
    if (process.env.MKDWARFS) {
        return process.env.MKDWARFS;
    }
    const system = spawnSync('mkdwarfs', ['--version'], {
        encoding: 'utf8',
    });
    if (!system.error) {
        return 'mkdwarfs';
    }
    return downloadPinnedExecutable(
        path.join('output', 'dwarfs'),
        'mkdwarfs',
        `https://github.com/mhx/dwarfs/releases/download/v${mkdwarfsVersion}` +
            `/dwarfs-universal-${mkdwarfsVersion}-Linux-${architecture}`,
        mkdwarfsChecksums[architecture],
    );
}

/** 取得 AppImage 运行时：DwarFS 镜像由 uruntime 挂载，squashfs 由 appimagetool 自带。 */
function resolveDwarfsRuntime(architecture) {
    if (process.env.URUNTIME) {
        return process.env.URUNTIME;
    }
    return downloadPinnedExecutable(
        path.join('output', 'dwarfs'),
        `uruntime-${architecture}`,
        `https://github.com/VHSgunzo/uruntime/releases/download/${uruntimeVersion}` +
            `/uruntime-appimage-dwarfs-lite-${architecture}`,
        uruntimeChecksums[architecture],
    );
}

/**
 * 生成 DwarFS 版 AppImage
 * mkdwarfs 直接输出带运行时的完整文件，跨文件去重后体积明显小于 squashfs。
 * -S 越大跨文件去重越充分，但随机读取要解压更多数据，启动变慢。
 */
const dwarfsCompressionOptions = (process.env.RHINE_DWARFS_OPTIONS || 'zstd:level=22 -S26 -B2').split(' ');

function packageDwarfsAppImage(app, image, architecture) {
    run(
        resolveDwarfsTool(architecture),
        [
            '--force',
            '--order=path',
            '--set-owner',
            '0',
            '--set-group',
            '0',
            '--no-history',
            '--no-create-timestamp',
            '--header',
            resolveDwarfsRuntime(architecture),
            '--input',
            app,
            '-C',
            dwarfsCompressionOptions[0],
            ...dwarfsCompressionOptions.slice(1),
            '--output',
            image,
        ],
        {
            ARCH: architecture,
        },
    );
    fs.chmodSync(image, 0o755);
    return image;
}

// 压缩参数：等级拉到上限，块大小提到 1 MiB（覆盖 appimagetool 预设的 128 KiB）。
// appimagetool 自带的 mksquashfs 是静态构建的 squashfs-tools-ng，只编译了 zstd：
// `mksquashfs: Compressor "xz" is not supported! Compressors available: zstd`。
// 所以 xz 与只属于 xz 的 -Xbcj 过滤器在这里都不可用，改用 zstd 最高等级逼近 xz 的体积。
// 每项按进程参数逐词传递，与命令行上逐个引用后的分词结果一致。
const appImageCompression = 'zstd';
const appImageSquashfsOptions = ['-Xcompression-level', '22', '-b', '1048576'];

function packageAppImage(app) {
    const architecture = process.arch === 'arm64' ? 'aarch64' : 'x86_64';
    const image = path.resolve(
        `output/RhineMusicDatabase-${packageIdentity()}-Linux-${architecture}.AppImage`,
    );
    fs.rmSync(image, {
        force: true,
    });
    pruneLinuxAppDir(app);
    // 默认走 DwarFS：跨文件去重后体积明显更小。挂载需要 FUSE，
    // 没有 FUSE 的机器上 uruntime 会退化成解包运行；RHINE_APPIMAGE_FS=squashfs 可回退。
    if (process.env.RHINE_APPIMAGE_FS !== 'squashfs') {
        return packageDwarfsAppImage(app, image, architecture);
    }
    // 透传参数用等号形式书写，避免以短横线开头的值被当作新选项。
    const args = [
        '--appimage-extract-and-run',
        `--comp=${appImageCompression}`,
        ...appImageSquashfsOptions.map((option) => `--mksquashfs-opt=${option}`),
        app,
        image,
    ];
    // 无 FUSE 的机器（容器、CI）也能打包；有 FUSE 时行为一致。
    run(resolveAppImageTool(architecture), args, {
        ARCH: architecture,
    });
    return image;
}

/**
 * 递归列出目录下的共享库
 * 显式递归而不依赖 readdirSync 的 recursive 选项，兼容旧版 Node。
 */
function sharedObjects(directory) {
    const found = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            found.push(...sharedObjects(full));
        } else if (entry.name.endsWith('.so')) {
            found.push(full);
        }
    }
    return found;
}

/**
 * 递归列出目录下的全部文件
 * 显式递归而不依赖 readdirSync 的 recursive 选项，兼容旧版 Node。
 */
function listFiles(directory) {
    const found = [];
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
        const full = path.join(directory, entry.name);
        if (entry.isDirectory()) {
            found.push(...listFiles(full));
        } else {
            found.push(full);
        }
    }
    return found;
}

// 发行版 Qt 的安装规则会把开发期文件一起装进前缀目录，运行时一律用不到。
// 只删这些确定无用的部分：程序、Qt 与 FFmpeg 的共享库本身都是运行必需的。
const linuxPrunedDirectories = [
    'usr/include',
    'usr/lib/cmake',
    'usr/lib/pkgconfig',
    'usr/share/man',
    'usr/share/doc',
    'usr/share/gtk-doc',
];
const linuxPrunedSuffixes = ['.a', '.la', '.prl'];

/**
 * 准备随包的自编 FFmpeg
 * 返回 SONAME 到本机路径的替换表；表为空表示继续沿用发行版库。
 */
function prepareLinuxFFmpeg(qt) {
    if (process.env.RHINE_FFMPEG === 'system') {
        return new Map();
    }
    run(process.execPath, ['scripts/prepare-linux-ffmpeg.cjs']);
    const libraries = new Map();
    const directory = path.join('output/dependencies/ffmpeg-linux/install/lib');
    for (const file of fs.readdirSync(directory)) {
        if (/\.so(?:\.\d+)*$/.test(file)) {
            libraries.set(file, path.join(directory, file));
        }
    }
    // Qt 的 FFmpeg 后端只认构建时链接的 SONAME。对不上时宁可包大，也不能没声音。
    const plugin = path.join(linuxQtQuery(qt, 'QT_INSTALL_PLUGINS'), 'multimedia/libffmpegmediaplugin.so');
    const required = [];
    if (fs.existsSync(plugin)) {
        const dynamic = spawnSync('readelf', ['-d', plugin], {
            encoding: 'utf8',
        });
        for (const line of (dynamic.stdout || '').split('\n')) {
            const match = /\[(lib(?:av\w+|sw\w+)\.so\.\d+)\]/.exec(line);
            if (match) {
                required.push(match[1]);
            }
        }
    }
    const missing = required.filter((name) => !libraries.has(name));
    if (missing.length) {
        const provided = [...libraries.keys()]
            .filter((name) => /\.so\.\d+$/.test(name))
            .sort()
            .join(', ');
        console.warn(
            `Self-built FFmpeg does not provide ${missing.join(', ')}; keep the distribution libraries`,
        );
        console.warn(`Self-built FFmpeg provides: ${provided || '(none)'}`);
        console.warn(
            'Falling back to the distribution libraries also pulls in libx264/libx265/libaom/libvpx/libdav1d/librav1e/libSvtAv1Enc.',
        );
        return new Map();
    }
    return libraries;
}

/**
 * 部署完成后核对随包的 FFmpeg 与视频编码库
 * 自编 FFmpeg 生效时，这七个编码器库不该有任何引用方；仍被引用则说明回退或漏替换，
 * 无人引用则说明依赖闭包又被打成了传递闭包（会白白多出几十 MB）。
 */
function reportLinuxBundle(app, ffmpegLibraries) {
    const directory = path.join(app, 'usr/lib');
    if (!fs.existsSync(directory)) {
        return;
    }
    const encoderPattern = /^lib(?:aom|x264|x265|vpx|dav1d|rav1e|SvtAv1Enc)\.so/;
    const encoders = fs.readdirSync(directory).filter((name) => encoderPattern.test(name));
    if (!encoders.length) {
        return;
    }
    const describe = (names) => {
        const total = names.reduce((sum, name) => sum + fs.statSync(path.join(directory, name)).size, 0);
        return `${names.length} 个库合计 ${(total / 1048576).toFixed(1)} MB: ${names.join(', ')}`;
    };
    const dependents = new Map();
    for (const name of fs.readdirSync(directory)) {
        const file = path.join(directory, name);
        if (encoderPattern.test(name) || !fs.lstatSync(file).isFile()) {
            continue;
        }
        const dynamic = spawnSync('readelf', ['-d', file], {
            encoding: 'utf8',
        });
        for (const line of (dynamic.stdout || '').split('\n')) {
            const match = /\(NEEDED\).*\[(\S+)\]/.exec(line);
            if (match && encoderPattern.test(match[1])) {
                dependents.set(match[1], [...(dependents.get(match[1]) || []), name]);
            }
        }
    }
    const used = encoders.filter((name) => dependents.has(name));
    const orphaned = encoders.filter((name) => !dependents.has(name));
    if (ffmpegLibraries.size && orphaned.length) {
        throw Error(`自编 FFmpeg 已生效，但包里仍有无人引用的编码器库（${describe(orphaned)}）`);
    }
    if (used.length) {
        const detail = used.map((name) => `${name} ← ${dependents.get(name).join(', ')}`).join('; ');
        console.warn(`包内含 ${describe(used)}，由非 FFmpeg 库直接引用：${detail}`);
    }
    if (orphaned.length) {
        console.warn(`包内含 ${describe(orphaned)}；自编 FFmpeg 未生效时会由发行版 libavcodec 带入。`);
    }
}

/** 删除 AppDir 里的开发期文件，压缩前再清一次，避免部署顺序影响结果。 */
function pruneLinuxAppDir(app) {
    for (const relative of linuxPrunedDirectories) {
        fs.rmSync(path.join(app, relative), {
            recursive: true,
            force: true,
        });
    }
    for (const file of listFiles(path.join(app, 'usr'))) {
        if (linuxPrunedSuffixes.some((suffix) => file.endsWith(suffix))) {
            fs.rmSync(file, {
                force: true,
            });
        }
    }
}

/**
 * 写入 AppImage 根目录的入口文件
 * AppRun 只补运行环境变量并转交参数，程序自身仍按 AppDir 前缀查找资源。
 */
function prepareLinuxAppDir(app) {
    const desktop = 'rhine-music-database.desktop';
    fs.writeFileSync(
        path.join(app, desktop),
        [
            '[Desktop Entry]',
            'Type=Application',
            'Name=RHINE MUSIC DATABASE',
            'GenericName=Music Library',
            'Comment=原生音乐资料库',
            'Exec=RhineMusicDatabase %U',
            'Icon=rhine-music-database',
            'Terminal=false',
            'Categories=AudioVideo;Audio;Player;',
            'StartupWMClass=RhineMusicDatabase',
            'X-AppImage-Name=RhineMusicDatabase',
            '',
        ].join('\n'),
    );
    fs.copyFileSync('Assets/icons/icon-256.png', path.join(app, 'rhine-music-database.png'));
    fs.copyFileSync('Assets/icons/icon-256.png', path.join(app, '.DirIcon'));
    const appRun = path.join(app, 'AppRun');
    fs.writeFileSync(
        appRun,
        [
            '#!/bin/sh',
            '# AppImage 入口：只补运行环境，参数原样转交。',
            'set -eu',
            'here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
            'export LD_LIBRARY_PATH="$here/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"',
            'export QT_PLUGIN_PATH="$here/usr/plugins"',
            'export QML_IMPORT_PATH="$here/usr/qml"',
            'export QT_QPA_PLATFORM_PLUGIN_PATH="$here/usr/plugins/platforms"',
            '# 没有显示服务器时提前说清楚：否则 Qt 只会甩一句 could not load the Qt platform plugin。',
            'if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then',
            '    echo "Rhine: 未检测到 DISPLAY 或 WAYLAND_DISPLAY：当前没有可用的显示服务器。" >&2',
            '    echo "Rhine: 纯 Xorg 会话请确认 DISPLAY 已导出；无头环境请用 --self-test。" >&2',
            'fi',
            '# 平台插件在启动时固定：纯 X11 / XWayland 用 RHINE_QPA_PLATFORM=xcb 强制走 X11。',
            'exit_code=0',
            '"$here/usr/bin/RhineMusicDatabase" "$@" || exit_code=$?',
            'exit "$exit_code"',
            '',
        ].join('\n'),
    );
    fs.chmodSync(appRun, 0o755);
}

/**
 * 组装独立应用并执行平台部署和签名，所有文件沿用原资源清单。
 */
function deployApp(qt, config, existingBundle = '') {
    const app = path.resolve(existingBundle || defaultAppPath);
    if (!existingBundle && fs.existsSync(app)) {
        fs.renameSync(app, app + '.previous-' + Date.now());
    }
    const resources = path.join(app, resourceDirectory);
    // Linux 先备好自编的 FFmpeg，再进入依赖闭包，避免把发行版的编码器库收进来。
    const ffmpegLibraries = linux ? prepareLinuxFFmpeg(qt) : new Map();
    if (mac && !existingBundle) {
        fs.cpSync('output/qt-build/RhineMusicDatabase.app', app, {
            recursive: true,
        });
    } else if (linux) {
        // AppImage 使用带前缀的 AppDir；程序与资源同目录，便于沿用现有资源查找顺序。
        // 走安装规则而非直接复制构建产物，才能带上相对 $ORIGIN 的 RPATH。
        run('cmake', ['--install', 'output/qt-build', '--prefix', path.join(app, 'usr')]);
        fs.chmodSync(path.join(app, 'usr/bin/RhineMusicDatabase'), 0o755);
    } else if (!mac) {
        fs.mkdirSync(app, {
            recursive: true,
        });
        fs.copyFileSync('output/qt-build/RhineMusicDatabase.exe', path.join(app, 'RHINE MUSIC DATABASE.exe'));
        fs.copyFileSync(
            'output/qt-build/RhinePlaybackService.exe',
            path.join(app, 'RhinePlaybackService.exe'),
        );
        for (const name of ['crashpad_handler.exe', 'RhineCrashReporter.exe', 'crashpad_wer.dll']) {
            fs.copyFileSync(path.join('output/qt-build', name), path.join(app, name));
        }
        for (const name of ['crash-tools', 'crash-symbols']) {
            fs.cpSync(path.join('output/qt-build', name), path.join(app, name), { recursive: true });
        }
    }

    fs.mkdirSync(resources, { recursive: true });
    if (process.platform === 'darwin') {
        // 清理旧布局的生成 helper，避免同一个包同时包含两种应用身份。
        fs.rmSync(path.join(app, 'Contents/MacOS/RhinePlaybackService'), { force: true });
    }
    if (mac) {
        fs.mkdirSync('output/qt-icon', {
            recursive: true,
        });
        run(path.join(app, 'Contents/MacOS/RhineMusicDatabase'), ['--make-icon', 'output/qt-icon'], {
            QT_QPA_PLATFORM: 'offscreen',
        });
        run(python, ['scripts/package-icon.py', 'output/qt-icon', path.join(resources, 'AppIcon.icns')]);
        for (const plugin of [
            'platforms/libqcocoa.dylib',
            'platforms/libqoffscreen.dylib',
            'imageformats/libqjpeg.dylib',
            'imageformats/libqgif.dylib',
            'imageformats/libqico.dylib',
            'tls/libqsecuretransportbackend.dylib',
            'networkinformation/libqapplenetworkinformation.dylib',
            'multimedia/libdarwinmediaplugin.dylib',
            'multimedia/libffmpegmediaplugin.dylib',
        ]) {
            const dest = path.join(app, 'Contents/PlugIns', plugin);
            fs.mkdirSync(path.dirname(dest), {
                recursive: true,
            });
            fs.copyFileSync(path.join(qt, 'plugins', plugin), dest);
        }
        deployMacAudioLibraries(qt, app);
        if (config === 'Debug') {
            for (const plugin of ['local', 'server', 'preview', 'quickprofiler', 'quickeventreplay']) {
                const dest = path.join(app, 'Contents/PlugIns/qmltooling', `libqmldbg_${plugin}.dylib`);
                fs.mkdirSync(path.dirname(dest), {
                    recursive: true,
                });
                fs.copyFileSync(path.join(qt, 'plugins/qmltooling', path.basename(dest)), dest);
            }
        }
        run(path.join(qt, 'bin/macdeployqt'), [
            app,
            '-qmldir=' + path.join(root, 'Qt/qml'),
            '-always-overwrite',
            '-executable=' +
                path.join(
                    app,
                    'Contents/Helpers/RhinePlaybackService.app/Contents/MacOS/RhinePlaybackService',
                ),
            '-no-plugins',
            // 资源尚未装入，嵌套 helper 也未封装签名；部署完成后统一由下方签名流程处理。
            '-no-codesign',
        ]);
        fs.writeFileSync(
            path.join(resources, 'qt.conf'),
            '[Paths]\nPrefix=.\nPlugins=PlugIns\nQmlImports=Resources/qml\n',
        );
        fs.rmSync(path.join(app, 'Contents/PlugIns/sqldrivers'), {
            recursive: true,
            force: true,
        });
    } else if (win) {
        run(path.join(qt, 'bin/windeployqt.exe'), [
            '--' + config.toLowerCase(),
            '--qmldir',
            path.join(root, 'Qt/qml'),
            '--no-translations',
            '--no-system-d3d-compiler',
            '--no-compiler-runtime',
            path.join(app, 'RHINE MUSIC DATABASE.exe'),
        ]);
        deployWindowsRuntime(app, config);
        // 系统网络状态后端通过插件动态载入，不能仅依靠可执行文件依赖扫描。
        const networkPlugins = path.join(qt, 'plugins/networkinformation');
        if (fs.existsSync(networkPlugins)) {
            const destination = path.join(app, 'networkinformation');
            fs.mkdirSync(destination, { recursive: true });
            for (const file of fs.readdirSync(networkPlugins)) {
                const isDebug = file.endsWith('d.dll');
                if (file.endsWith('.dll') && isDebug === (config === 'Debug')) {
                    fs.copyFileSync(path.join(networkPlugins, file), path.join(destination, file));
                }
            }
        }
        // windeployqt 默认只带 Windows 平台插件；离线发布包测试也需要 offscreen 插件。
        const offscreen = config === 'Debug' ? 'qoffscreend.dll' : 'qoffscreen.dll';
        fs.mkdirSync(path.join(app, 'platforms'), {
            recursive: true,
        });
        fs.copyFileSync(
            path.join(qt, 'plugins/platforms', offscreen),
            path.join(app, 'platforms', offscreen),
        );
        fs.writeFileSync(path.join(app, 'qt.conf'), '[Paths]\nPlugins=.\nQmlImports=qml\n');
        fs.rmSync(path.join(app, 'sqldrivers'), {
            recursive: true,
            force: true,
        });
    }
    if (linux) {
        prepareLinuxAppDir(app);
        deployLinuxRuntime(qt, app, path.join(app, 'usr/bin/RhineMusicDatabase'), ffmpegLibraries);
        reportLinuxBundle(app, ffmpegLibraries);
    }
    // 先部署 Qt，再装入大量 SDK 文件，避免部署工具逐个扫描非原生依赖。
    run(process.execPath, ['scripts/package-resources.cjs', resources]);
    fs.copyFileSync('LICENSE', path.join(resources, 'LICENSE'));
    // 只复制第三方库的许可证文件，不复制源码包。
    const thirdParty = path.join(resources, 'third-party');
    fs.mkdirSync(path.join(thirdParty, 'taglib'), { recursive: true });
    fs.mkdirSync(path.join(thirdParty, 'utfcpp'), { recursive: true });
    fs.copyFileSync(path.join('vendor/taglib/COPYING.LGPL'), path.join(thirdParty, 'taglib/COPYING.LGPL'));
    fs.copyFileSync(path.join('vendor/taglib/COPYING.MPL'), path.join(thirdParty, 'taglib/COPYING.MPL'));
    fs.copyFileSync(path.join('vendor/taglib/source.json'), path.join(thirdParty, 'taglib/source.json'));
    fs.copyFileSync(path.join('vendor/utfcpp/LICENSE'), path.join(thirdParty, 'utfcpp/LICENSE'));
    fs.copyFileSync(path.join('vendor/utfcpp/source.json'), path.join(thirdParty, 'utfcpp/source.json'));
    // 随包的 FFmpeg 以 LGPL-2.1-or-later 构建，许可全文、来源与构建参数一起进包。
    if (ffmpegLibraries.size) {
        const ffmpeg = path.join(thirdParty, 'FFmpeg');
        fs.mkdirSync(ffmpeg, { recursive: true });
        fs.cpSync('licenses/FFmpeg', ffmpeg, { recursive: true });
        fs.copyFileSync('vendor/ffmpeg/source.json', path.join(ffmpeg, 'source.json'));
        fs.copyFileSync(
            path.join('output/dependencies/ffmpeg-linux/install/build.json'),
            path.join(ffmpeg, 'build.json'),
        );
    }
    fs.copyFileSync('vendor/qrcodegen/qrcodegen.hpp', path.join(resources, 'qrcodegen-LICENSE.hpp'));
    fs.cpSync('licenses/Qt', path.join(resources, 'Qt-Licenses'), {
        recursive: true,
    });
    // Linux 的 Qt 由发行版安装，许可文件位置不固定，沿用仓库内的清单。
    const qtLicenses = linux ? '' : path.resolve(qt, '../../Licenses');
    if (qtLicenses && fs.existsSync(qtLicenses)) {
        fs.cpSync(qtLicenses, path.join(resources, 'Qt-Licenses'), {
            recursive: true,
        });
    }
    if (mac) {
        run('codesign', ['--force', '--sign', '-', path.join(resources, 'MusicBridge/node')]);
        // 先封装 helper 的资源签名，再签外层应用，避免沿用链接器留下的裸可执行文件签名。
        run('codesign', [
            '--force',
            '--sign',
            '-',
            path.join(app, 'Contents/Helpers/RhinePlaybackService.app'),
        ]);
        run('codesign', ['--force', '--deep', '--sign', '-', app]);
        run('codesign', ['--verify', '--deep', '--strict', app]);
    }
    if (linux) {
        const image = packageAppImage(app);
        return image;
    }
    return app;
}
prepareResources();
if (process.argv[2] === '--resources-only') {
    console.log('Resources prepared');
} else if (process.argv[2] === '--cmake-package') {
    // Qt Creator 的链接产物原地打包，不再次启动 CMake 或覆盖其他构建目录。
    const [, , , bundle, qt, config] = process.argv;
    if (!mac || !bundle || !qt || !config) {
        throw new Error('CMake packaging requires a macOS bundle, Qt kit and build configuration');
    }
    // 原地打包不会经过 buildQt，仍要生成与当前二进制匹配的采集器、解析器和符号。
    let buildDirectory = path.dirname(path.resolve(bundle));
    while (!fs.existsSync(path.join(buildDirectory, 'CMakeCache.txt'))) {
        const parent = path.dirname(buildDirectory);
        if (parent === buildDirectory) {
            throw new Error('Cannot locate the CMake build directory for RhineCrashSymbols');
        }
        buildDirectory = parent;
    }
    run('cmake', ['--build', buildDirectory, '--target', 'RhineCrashSymbols']);
    console.log(deployApp(qt, config, path.resolve(bundle)));
} else {
    const { qt, config } = buildQt();
    console.log(deployApp(qt, config));
}
