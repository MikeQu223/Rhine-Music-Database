/**
 * Rhine Music Database 插件 Port v1。
 *
 * 这是 core 与插件之间的唯一领域契约。Qt 业务层只依赖本文件定义的
 * Port、统一模型和 Caps；不得依赖任何平台字段或原始路由。
 *
 * 设计约束：
 * - 所有模型字段都是 core 语义；平台差异放 extensions，key 必须带插件前缀。
 * - 音质用不透明 qualityId + 归一化 tier；core 不做平台音质翻译。
 * - 喜欢状态统一为 likedState；不暴露 subscriptionStatus/likedIDs 差异。
 * - 登录统一为 login.*；不暴露二维码/短信/QQ/微信分支。
 * - 原始路由只在插件内部使用，不暴露给 Qt。
 */

export type ProviderId = string;
export type EntityKind = 'song' | 'album' | 'artist' | 'playlist' | 'mv';
export type LikeState = 'liked' | 'not-liked' | 'unknown';
export type QualityTier = 'auto' | 'standard' | 'hq' | 'lossless' | 'hires' | 'master' | 'original';

export interface ProviderManifest {
    schemaVersion: 1;
    apiVersion: string;
    id: ProviderId;
    version: string;
    kind?: 'official' | 'third-party' | 'builtin';
    publisher?: string;
    keyId?: string;
    requiresHost?: string;
    entry: { file: string; sha256: string; size: number };
    files?: Array<{ path: string; sha256: string; size: number }>;
    routes?: {
        prefixes?: string[];
        rawRoutes?: string[];
        legacyRoutes?: string[];
    };
    operations?: Record<string, boolean>;
    credentials?: {
        namespace: string;
        shape: 'opaque';
        secretState?: boolean;
        deviceState?: boolean;
        variants?: string[];
    };
    display?: ProviderDisplay;
    library?: ProviderLibrary;
    search?: ProviderSearch;
    quality?: ProviderQuality;
    login?: ProviderLogin;
    discover?: ProviderDiscover;
    capabilities?: ProviderCapabilities;
    lyrics?: ProviderLyrics;
    media?: ProviderMedia;
    network?: ProviderNetwork;
    cache?: ProviderCache;
    limits?: ProviderLimits;
    upstream?: Array<Record<string, unknown>>;
    strings?: Record<string, string>;
    links?: ProviderLinks;
}

export interface ProviderDisplay {
    name: string;
    nameByVariant?: Record<string, string>;
    label: string;
    detail: string;
    sessionLabel?: string;
    archiveIdPrefix?: string;
    order?: number;
    default?: boolean;
}

export interface ProviderLibrary {
    columns?: string[];
    sourceOrder?: number[];
    lanes?: number;
    visibleLanes?: number[];
    identityProviders?: ProviderId[];
    likedModel?: 'likedIDs' | 'likedSongs' | 'local';
    playlistNameMaxLength?: number;
    playlistEditableRule?: 'all' | 'owned' | 'owned-with-dir-range' | 'none';
    dirIdRange?: [number, number] | null;
}

export interface ProviderSearch {
    enabled?: boolean;
    maxQueryLength?: number;
    suggest?: boolean;
    parseLinks?: boolean;
    linkPatterns?: string[];
}

export interface ProviderQuality {
    default: string;
    options: Array<{
        id: string;
        label: string;
        tier: QualityTier;
        badge?: string;
        featured?: boolean;
    }>;
    aliases?: Record<string, string>;
}

export interface ProviderLogin {
    required?: boolean;
    methods: Array<{
        id: string;
        type: 'qr' | 'sms' | 'password' | 'token';
        label: string;
        channel?: string;
        phonePattern?: string;
        countryCode?: string;
        resendCooldownMs?: number;
    }>;
    variants?: string[];
    pollIntervalMs?: number;
    pollTimeoutMs?: number;
    failureMessages?: Record<string, string>;
}

export interface ProviderDiscover {
    enabled: boolean;
    defaultTab?: string;
    tabs?: Array<{ id: string; label: string }>;
}

export interface ProviderCapabilities {
    search?: boolean;
    suggest?: boolean;
    resolveLink?: boolean;
    detail?: boolean;
    playback?: boolean;
    preview?: boolean;
    lyrics?: boolean;
    account?: boolean;
    login?: boolean;
    vip?: boolean;
    discover?: boolean;
    categories?: boolean;
    userPlaylists?: boolean;
    likedSongs?: boolean;
    likedAlbums?: boolean;
    mv?: boolean;
    officialPlayback?: boolean;
    alternativeSource?: boolean;
    mutations?: Record<string, boolean>;
    playlistManagement?: Record<string, boolean>;
}

export interface ProviderLyrics {
    sources: string[];
    fallback?: string[];
    matchMode?: 'strict' | 'fuzzy';
    rateLimitMs?: number;
    retryDelaysMs?: number[];
}

export interface ProviderMedia {
    hosts: string[];
    alternativeHosts?: string[];
    coverHosts?: string[];
    allowHttp?: boolean;
    schemePolicy?: 'https' | 'http-or-https';
}

export interface ProviderNetwork {
    hosts?: string[];
    credentialHosts?: string[];
    allowLoopback?: boolean;
    preserveHttpHosts?: string[];
}

export interface ProviderCache {
    namespace: string;
    ttlByOperation?: Record<string, number>;
    diskOperations?: string[];
}

export interface ProviderLimits {
    memoryMB?: number;
    operationTimeoutMs?: number;
    playbackTimeoutMs?: number;
    maxConcurrent?: number;
    maxResponseBytes?: number;
}

export interface ProviderLinks {
    parse?: boolean;
    patterns?: string[];
    webTemplates?: Record<string, string>;
    officialAppUrl?: string;
    officialLabel?: string;
}

export interface EntityRef {
    provider: ProviderId;
    kind: EntityKind;
    id: string;
}

export interface ArtistRef {
    id: string;
    name: string;
}

export interface AlbumRef {
    id: string;
    title: string;
    artists?: ArtistRef[];
    cover?: string;
}

export interface EntityExtensionFields {
    owned?: boolean;
    dirId?: string;
    listid?: string;
    listType?: number;
    chart?: boolean;
    period?: string;
    rankCid?: string;
    isDefault?: boolean;
    isFavorite?: boolean;
    playCount?: number;
    virtual?: boolean;
    extensions?: Record<string, unknown>;
}

export interface Track extends EntityRef, EntityExtensionFields {
    kind: 'song';
    key: string;
    title: string;
    artist: string;
    artists: ArtistRef[];
    creatorID?: string;
    albumID?: string;
    album?: string;
    albumAudioID?: string;
    mediaId?: string;
    songID?: number;
    songType?: number | null;
    cover?: string;
    description?: string;
    wiki?: string;
    date?: string;
    duration?: number;
    trackCount?: number;
    mvID?: string;
    special?: boolean;
}

export interface Album extends EntityRef, EntityExtensionFields {
    kind: 'album';
    key: string;
    title: string;
    artist: string;
    artists: ArtistRef[];
    creatorID?: string;
    cover?: string;
    description?: string;
    date?: string;
    duration?: number;
    trackCount?: number;
    special?: boolean;
}

export interface Artist extends EntityRef, EntityExtensionFields {
    kind: 'artist';
    key: string;
    title: string;
    artist: string;
    artists: ArtistRef[];
    creatorID?: string;
    cover?: string;
    description?: string;
    date?: string;
    duration?: number;
    trackCount?: number;
    special?: boolean;
}

export interface Playlist extends EntityRef, EntityExtensionFields {
    kind: 'playlist';
    key: string;
    title: string;
    artist: string;
    artists: ArtistRef[];
    creatorID?: string;
    cover?: string;
    description?: string;
    date?: string;
    duration?: number;
    trackCount?: number;
    special?: boolean;
}

export type MusicEntity = Track | Album | Artist | Playlist;

export interface Page<T extends MusicEntity = MusicEntity> {
    items: T[];
    rawCount: number;
    total?: number;
    more: boolean;
    notice?: string;
    incomplete?: boolean;
    category?: string;
    areas?: Array<{ id: string; name: string }>;
    area?: number;
}

export type Detail = [MusicEntity, Track[], string[]];

export interface PlaybackSource {
    url: string;
    format?: string;
    bitrate?: number;
    sampleRate?: number;
    bitDepth?: number;
    tier: QualityTier;
    providerTier?: string;
    qualityId?: string;
    trial?: boolean;
    restriction?: string;
    qualityFallback?: string;
}

export interface LyricWord {
    startMs: number;
    endMs?: number;
    text: string;
}

export interface LyricLine {
    startMs: number;
    endMs?: number | null;
    text: string;
    translation?: string;
    words?: LyricWord[];
}

export interface LyricsDocument {
    version: 1;
    source: string;
    timing: 'none' | 'line' | 'word';
    offsetMs: number;
    lines: LyricLine[];
    plainText?: string;
}

export type Account = [id: string, nickname: string];

export interface Capabilities extends ProviderCapabilities {
    loginMethods?: string[];
}

export interface VipStatus {
    isVip?: boolean | string | number;
    vipLevel?: string;
}

export type SubscriptionStatus = 'subscribed' | 'not-subscribed' | 'unknown';

export interface MutationAction {
    action: string;
    target?: EntityRef;
    values?: Record<string, unknown>;
    requestId?: string;
}

export interface MutationResult {
    applied: boolean;
    state?: LikeState | SubscriptionStatus | string;
    item?: MusicEntity;
    countDelta?: number;
}

export interface ProviderErrorShape {
    code: number;
    message: string;
    authExpired?: boolean;
    retryAfterMs?: number;
    failureStage?: string;
    failureReason?: string;
    errorKey?: string;
    upstreamErrorKey?: string;
    upstreamHttpStatus?: number;
    upstreamCode?: number;
    upstreamGlobalCode?: number;
    upstreamSubCode?: number;
    retryable?: boolean;
    writeAttempted?: boolean;
    verification?: 'unconfirmed';
}

export interface SearchQuery {
    text: string;
    kind: 'song' | 'album' | 'artist' | 'playlist';
    offset?: number;
}

export interface PageQuery {
    offset?: number;
    category?: string;
    area?: string;
}

export interface LoginFlow {
    begin(options: { method: string; channel?: string }): Promise<LoginSession>;
    poll(sessionId: string): Promise<LoginPollResult>;
    cancel(sessionId: string): Promise<void>;
    sms?: {
        send(phone: string): Promise<{ retryAfterMs?: number }>;
        verify(phone: string, code: string): Promise<LoginPollResult>;
    };
}

export interface LoginSession {
    sessionId: string;
    qr?: { kind: 'content' | 'image'; value: string };
    expiresAt?: number;
}

export interface LoginPollResult {
    state: 'waiting' | 'scanned' | 'confirmed' | 'expired' | 'error';
    account?: Account;
    message?: string;
}

export interface Health {
    ok: boolean;
    latencyMs?: number;
    message?: string;
}

export interface RequestOptions {
    allowedCodes?: number[];
    timeoutMs?: number;
    maxBytes?: number;
}

export interface ProviderResponse {
    body: unknown;
    cookies?: string[];
}

export interface HttpRequest {
    url: string;
    method?: string;
    headers?: Record<string, string>;
    body?: string | Uint8Array;
    timeoutMs?: number;
    maxBytes?: number;
    redirect?: 'follow' | 'error' | 'manual';
}

export interface HttpResponse {
    status: number;
    headers: Record<string, string>;
    body: Uint8Array;
}

export interface CredentialStore {
    get(): Promise<Record<string, unknown> | null>;
    update(value: Record<string, unknown>): Promise<void>;
    acceptSetCookie(lines: string[]): Promise<void>;
}

export interface SecretStateStore {
    get(): Promise<Record<string, unknown> | null>;
    set(value: Record<string, unknown> | null): Promise<void>;
}

export interface PluginStorage {
    get(key: string): Promise<unknown>;
    set(key: string, value: unknown): Promise<void>;
    remove(key: string): Promise<void>;
}

export interface PluginDiagnostics {
    record(fields: Record<string, number | boolean | string>): void;
}

export interface PluginHost {
    request(
        route: string,
        params?: Record<string, unknown>,
        options?: RequestOptions,
    ): Promise<ProviderResponse>;
    http(request: HttpRequest): Promise<HttpResponse>;
    credentials: CredentialStore;
    secretState: SecretStateStore;
    storage: PluginStorage;
    deviceStatePath(): string;
    tempDir(): string;
    variant(): string | null;
    authenticated(): boolean;
    delay(milliseconds: number): Promise<void>;
    log(level: 'debug' | 'info' | 'warn' | 'error', event: string, fields?: Record<string, unknown>): void;
    diagnostics: PluginDiagnostics;
    signal: AbortSignal;
    registerCleanup(fn: () => void | Promise<void>): void;
    onDispose(fn: () => void | Promise<void>): void;
}

/**
 * 插件实现的最小入口。所有 operation 都是可选的；未实现时由 host 根据
 * capabilities 返回 400/501，不静默回退到其他 provider。
 */
export interface ProviderAdapter {
    search?(query: SearchQuery): Promise<Page<Track>>;
    suggest?(query: string): Promise<string[]>;
    resolveLink?(text: string): Promise<EntityRef | null>;

    songs?(ids: string[]): Promise<Track[]>;
    detail?(ref: EntityRef): Promise<Detail>;
    artistAlbums?(id: string, page?: PageQuery): Promise<Page<Album>>;
    trackPage?(ref: EntityRef, page?: PageQuery): Promise<Page<Track>>;
    catalog?(): Promise<Page<MusicEntity>>;

    playback?(ref: Track, qualityId: string, alternative: boolean): Promise<PlaybackSource>;
    preview?(ref: Track, qualityId: string, alternative: boolean): Promise<PlaybackSource>;
    lyrics?(ref: Track): Promise<LyricsDocument | null>;

    account?(): Promise<Account | null>;
    login?: LoginFlow;
    logout?(): Promise<void>;
    vip?(): Promise<VipStatus>;

    userPlaylists?(uid?: string): Promise<Playlist[]>;
    likedIDs?(): Promise<string[]>;
    likedSongs?(page?: PageQuery): Promise<Page<Track>>;
    likedAlbums?(page?: PageQuery): Promise<Page<Album>>;
    likedState?(ids: string[]): Promise<Record<string, LikeState>>;

    discover?(tab: string, page?: PageQuery): Promise<Page<MusicEntity>>;
    categories?(): Promise<Array<{ id: string; name: string }>>;

    mutate?(action: MutationAction): Promise<MutationResult>;

    capabilities(): Promise<Capabilities>;
    health?(): Promise<Health>;

    dispose?(): Promise<void>;
}

export interface PluginModule {
    manifest: ProviderManifest;
    create(host: PluginHost): ProviderAdapter | Promise<ProviderAdapter>;
}
