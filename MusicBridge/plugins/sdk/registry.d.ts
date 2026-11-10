/**
 * Rhine Music Database Registry 契约 v2。
 *
 * Registry 是唯一知道 provider ID 的基础设施；Qt 业务层只通过 Registry
 * 获取 descriptor/能力，不得比较 provider 字符串。
 *
 * 状态机：
 *   missing -> bundled | installed
 *   bundled | installed -> disabled | incompatible | quarantined | failed
 *   disabled -> installed | bundled
 *   incompatible -> missing (安装兼容版本后重新注册)
 *   quarantined -> disabled | installed (人工解除)
 */

import type {
    ExternalPlayback,
    PluginRuntime,
    ProviderCache,
    ProviderCapabilities,
    ProviderDiscover,
    ProviderDisplay,
    ProviderId,
    ProviderLibrary,
    ProviderLinks,
    ProviderLogin,
    ProviderLyrics,
    ProviderManifest,
    ProviderMedia,
    ProviderQuality,
    ProviderRuntimeConfig,
    ProviderSearch,
    ProviderVariant,
} from './port';

export type ProviderStatus =
    'missing' | 'bundled' | 'installed' | 'disabled' | 'incompatible' | 'quarantined' | 'failed';

export type ProviderSource = 'bundled' | 'installed';

export interface ProviderRegistration {
    manifest: ProviderManifest;
    status: ProviderStatus;
    source: ProviderSource;
    path?: string;
    error?: string;
}

/**
 * descriptor 是 manifest 的纯数据子集，供 Qt 渲染。
 * 它不包含入口、hash、许可证等安装元数据。
 */
export interface ProviderDescriptor {
    schemaVersion: 2;
    id: ProviderId;
    display: ProviderDisplay;
    variants?: ProviderVariant[];
    variantPreference?: string;
    capabilities: ProviderCapabilities;
    operations?: Record<string, boolean>;
    library?: ProviderLibrary;
    search?: ProviderSearch;
    quality?: ProviderQuality;
    login?: ProviderLogin;
    discover?: ProviderDiscover;
    lyrics?: ProviderLyrics;
    media?: ProviderMedia;
    externalPlayback?: ExternalPlayback;
    cache?: ProviderCache;
    runtime?: ProviderRuntimeConfig;
    attribution?: string;
    links?: ProviderLinks;
    strings?: Record<string, string>;
}

export interface ProviderRegistry {
    /** 已注册 provider 的完整列表（含缺失/禁用状态？只列出已发现项）。 */
    list(): ProviderRegistration[];

    /** 供 Qt 渲染的 descriptor 列表；只包含 bundled/installed 且版本兼容的 provider。 */
    descriptors(): ProviderDescriptor[];

    /** 获取已加载的适配器；未加载/不可用时返回 null。 */
    get(id: ProviderId): PluginRuntime | null;

    /** 获取适配器；不可用时抛 ProviderUnavailableError。 */
    require(id: ProviderId): PluginRuntime;

    /** 默认 provider；没有可用 provider 时返回 null，不回退到某个平台。 */
    default(): ProviderId | null;

    /** 路由一次统一 operation；未声明能力时抛 ProviderUnsupportedError。 */
    route(id: ProviderId, operation: string, args?: unknown[]): Promise<unknown>;

    /** 该 provider 是否声明支持某 operation。 */
    can(id: ProviderId, operation: string): boolean;

    /** 当前状态。 */
    status(id: ProviderId): ProviderStatus;

    /** 卸载所有适配器；不删除插件文件。 */
    dispose(): Promise<void>;
}

export class ProviderUnavailableError extends Error {
    readonly providerId: ProviderId;
    readonly status: ProviderStatus;
    constructor(providerId: ProviderId, status: ProviderStatus, message?: string);
}

export class ProviderUnsupportedError extends Error {
    readonly providerId: ProviderId;
    readonly operation: string;
    constructor(providerId: ProviderId, operation: string, message?: string);
}

export class ProviderContractError extends Error {
    readonly providerId: ProviderId;
    readonly operation: string;
    readonly path: string;
    constructor(providerId: ProviderId, operation: string, path: string, message: string);
}
