#pragma once
#include "MusicPlayer.h"
#include "CommentsController.h"
#include "LocalMusicLibrary.h"
#include "LocalCollections.h"
#include <QHash>
#include <QSet>
#include <array>
#include <memory>

class MusicDiscover;

struct MusicDirectory {
    std::shared_ptr<MusicDirectory> parent;
    QJsonObject item;
    QJsonArray songs;
    QString sortField = "none";
    QJsonArray orderedSongs() const;
    void updateSongs(QJsonArray values, QString field);
    mutable QJsonArray cachedSongs;
    mutable QJsonArray sortedSongs;
    mutable QString cachedSortField;
    QJsonArray ids;
    QJsonArray albums;
    int cursor = 0;
    int index = 0;
    int anchor = 0;
    int page = 0;
    int parentPhysical = 0;
    int parentLane = 0;
    QJsonObject parentItem;
    int albumCursor = 0;
    bool albumsMore = false;
    bool albumsLoading = false;
};

class MusicLibrary : public QObject {
    Q_OBJECT
  public:
    using Completion = std::function<void(bool)>;
    MusicLibrary(Host *host, const QJsonObject &content, QObject *parent = nullptr);
    ~MusicLibrary() override;
    QJsonObject sessionState() const;
    bool restoreSessionState(const QJsonObject &saved);
    void changed();
    bool isLocal() const {
        return provider == "local";
    }
    bool isSiren() const {
        return provider == "siren";
    }
    void refreshLocal();
    void loadSirenSource(int lane);
    void loadSirenCatalog();
    void searchSirenLocal(QString query, QString kind, int start, bool more);
    bool openSirenAllSongs();
    void clearCaches();
    void searchLocal(QString text, QString kind = {});
    void importLocal(const QStringList &paths);
    std::unique_ptr<LocalMusicLibrary> local;
    std::unique_ptr<LocalCollections> collections;
    void reloadSirenCollections();
    void observe(int selected);
    void choose(QJsonObject value, bool containerDetails = false,
                std::optional<bool> showDetails = std::nullopt);
    void search(QString text, QString kind = {}, bool more = false);
    void suggest(QString text);
    void showSource(int lane);
    void selectResult(int index, int lane, bool open = true);
    void selectLibraryIndex(int index);
    void next(int direction);
    void loadMoreSource(int lane);
    void refreshPersonal(int lane);
    void loadTrackPage(int start);
    void sameAlbum();
    void loadSongWiki();
    void play(bool byUser = true);
    void playDirectory(bool includeAllSongSources = false);
    void playCollection(QJsonObject value);
    void playOfficial(QJsonObject value = {});
    struct QueueSource {
        QJsonArray ids;
        QJsonArray items;
    };
    QueueSource directorySource() const;
    QueueSource currentSource() const;
    QString sourceURL(QJsonObject value = {}) const;
    void setGroupView(QString name, QVector<int> indices = {}, int lane = 0);
    QJsonArray sourceItems(int lane) const;
    QJsonArray libraryItems() const;
    QString libraryName() const;
    QVector<int> sourceOrder() const;
    bool laneVisible(int lane) const;
    int libraryTotal() const;
    int libraryIndex() const;
    QString providerName() const;
    QString accountKey() const;
    QString identityName() const;
    bool editable() const;
    bool sourceLoading() const {
        return restoringAccount || searchLoading || personalLoading || sirenCatalogLoading;
    }
    QString sourceMessage(int lane) const;
    bool restoringAccount = false;
    quint64 accountGeneration() const {
        return m_accountGeneration;
    }
    void switchProvider(QString provider, QString edition = {}, Completion done = {});
    void restoreAccount(Completion done = {});
    void restoreIdentityName();
    void startLogin();
    void cancelLogin(Completion done = {});
    void sendLoginCode(QString phone);
    void captchaLogin(QString phone, QString captcha);
    int smsRetrySeconds() const;
    void logout();
    int loginRetrySeconds() const;
    bool canRegenerateLogin() const;
    void mutate(QString route, QJsonObject values, std::function<void(QJsonObject)> success,
                Completion done = {});
    void like(QJsonObject value = {});
    void subscribe(QJsonObject value = {});
    void playlistForm(QString kind, QString name, QString id = {}, Completion done = {});
    void playlistTrack(QString id, QJsonObject value = {}, bool remove = false, Completion done = {});
    void enterDirectory(QJsonObject value);
    bool openDaily();
    void loadArtistAlbums();
    void openSongArtist(int index = 0);
    void observeDirectory(int physical);
    void selectDirectory(int index, QString mode = "archive", QString axis = "row", int direction = 1);
    void navigateDirectory(int step, QString axis = {});
    void loadDirectoryPage(std::optional<int> selectAfter = std::nullopt);
    void setDirectorySort(QString field);
    void showDirectoryInfo();
    void returnToDirectory();
    void leaveDirectory(bool restore = true);
    void followPlayback(QJsonObject track, bool showDetails = true);
    bool followPlaybackDetails = true;
    Host *host;
    MusicApi api;
    MusicPlayer player;
    CommentsController comments;
    std::unique_ptr<MusicDiscover> discover;
    std::array<QJsonArray, 5> lists;
    std::array<int, 5> totals{};
    std::array<int, 5> offsets{};
    std::array<int, 5> sirenOffsets{};
    QJsonArray sirenSongs;
    QJsonArray sirenAlbums;
    bool sirenCatalogLoading = false;
    bool m_pendingSirenSearch = false;
    std::array<bool, 5> hasMore{true, true, true, true, true};
    std::array<int, 5> rowMemory{};
    std::array<QVector<int>, 5> physicalSlots;
    QStringList columns{"搜索结果", "喜欢的歌曲", "我的歌单", "收藏歌单", "收藏专辑"};
    QJsonObject current;
    QJsonArray tracks;
    QJsonArray trackIDs;
    // 记录当前单曲被选中时所在的歌曲列表
    QJsonArray playContext;
    QHash<QString, QJsonObject> details;
    QString searchKind = "song";
    QString keyword;
    QString status = "输入关键词检索音乐";
    QString provider;
    QString providerVariant;
    QString uid;
    QString nickname = "未登录";
    QHash<QString, QString> identityNames;
    int selectedPhysical = -1;
    int selectedLane = 0;
    bool detailLoading = false;
    QString coverImage;
    QString coverKey;
    QString qr;
    QString qrKey;
    QString loginStatus;
    QString loginPhase = "idle";
    QString loginMethod = "qr";
    QJsonObject loginDiagnostics;
    bool accountLoading = false;
    bool wantsSongDetails = false;
    std::shared_ptr<MusicDirectory> directory;
    bool directoryLoading = false;
    bool directoryInfo = false;
    bool searchLoading = false;
    bool personalLoading = false;
    bool trackLoad = false;
    bool albumLoaded = false;
    bool writeLoading = false;
    bool privateSelection = false;
    int searchCursor = 0;
    int playlistCursor = 0;
    int albumCursor = 0;
    int likedCursor = 0;
    int trackCursor = 0;
    std::optional<QJsonArray> likedIDs;
    QSet<QString> subscriptions;
    QHash<QString, QString> subscriptionStates;
    void loadSubscriptionStatus(const QJsonObject &value);
    bool isSubscribed(const QJsonObject &value) const;
    std::optional<bool> songLiked(const QJsonObject &value) const;
    QJsonObject capabilities;
    QString vipLevel = "unknown";
    void refreshAccountFeatures();
    bool canEditPlaylist(const QJsonObject &value) const;
    bool canMutate(const QString &route) const;
    bool supportsOperation(const QString &operation) const;
    bool commentsAvailable() const;
    QStringList searchHistory;
    QStringList suggestions;
    QString groupName;
    QVector<int> groupIndices;
    int groupLane = -1;
    QJsonObject frame;
    quint64 revision = 0;

  signals:
    void invalidated();
    void playbackInvalidated();
    void selectionRequested(int index, QJsonObject navigation);
    void modeRequested(QString mode);
    void navigationRequested(QString axis, int direction);
    void musicIdentityRequested(QString key);
    void musicClearRequested();

  private:
    void searchInternal(QString text, QString kind, bool more);
    struct Cooldown {
        qint64 deadline = 0;
        QString message;
        quint64 token = 0;
    };
    struct Cancellation {
        QVector<Completion> waiters;
    };
    QHash<QString, std::shared_ptr<Cancellation>> m_cancellations;
    QHash<QString, Cooldown> m_cooldowns;
    quint64 m_generation = 0;
    quint64 m_selectionGeneration = 0;
    quint64 m_collectionPlayGeneration = 0;
    quint64 m_accountGeneration = 0;
    quint64 m_directoryGeneration = 0;
    quint64 m_wikiGeneration = 0;
    quint64 m_suggestGeneration = 0;
    quint64 m_subscriptionGeneration = 0;
    quint64 m_playbackLikeGeneration = 0;
    QString m_playbackLikeContext;
    void refreshPlaybackLike();
    void resetLikeState();
    quint64 m_loginGeneration = 0;
    quint64 m_cooldownGeneration = 0;
    qint64 m_smsRetryAtMs = 0;
    MusicApi m_identityApi;
    MusicApi::Valid valid(quint64 token, const quint64 *counter);
    void loadCover(const QJsonObject &value);
    void loadLikedIDs(int lane, quint64 token, QString user);
    void completePersonal(int lane, QString error = {});
    int m_pendingLane = -1;
    bool m_playLiked = false;
    struct SourcePlayback {
        int lane = 0;
        quint64 account = 0;
        quint64 search = 0;
        quint64 selection = 0;
        int cursor = 0;
        bool awaitingPage = false;
    };
    std::optional<SourcePlayback> m_sourcePlayback;
    bool m_sourcePlaybackScheduled = false;
    void continueSourcePlayback();
    QString m_accountError;
    std::array<QString, 5> m_sourceErrors;
    void restoreCachedAccount();
    void rememberIdentityName(QString provider, QString name);
    void reportLoginFailure(const QJsonObject &details, QString message = {});
    void updateLoginCooldown(QString source, Cooldown cooldown);
    void prepareQR(quint64 token);
    void pollQR(quint64 token, int count);
    void confirmLogin(quint64 token, bool captcha = false);
    void updateSmsCooldown();
    void failLogin(const MusicReply &result);
};
