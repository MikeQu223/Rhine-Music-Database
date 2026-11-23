#pragma once
#include "MusicApi.h"
#include <QHash>
#include <QStringList>
class MusicLibrary;

class MusicDiscover {
  public:
    struct SectionState {
        QJsonArray items;
        QString status;
        int offset = 0;
        bool loading = false;
        bool attempted = false;
        bool failed = false;
        bool more = false;
        quint64 generation = 0;
    };
    explicit MusicDiscover(MusicLibrary *store);
    void load(QString tab = {}, bool more = false);
    void loadSections();
    void ensureSection(const QString &id, bool preserve = false);
    void openSection(const QString &id, int index);
    void playSection(const QString &id, int index);
    void loadCategories();
    void cancel();
    void open(int index);
    QString tab = "playlists";
    QJsonArray items;
    bool loading = false;
    QString status;
    quint64 generation = 0;
    int offset = 0;
    bool more = false;
    QString category = "全部";
    QJsonArray categories;
    bool categoriesLoading = false;
    QString categoryStatus;
    quint64 categoriesGeneration = 0;
    QJsonArray newSongAreas;
    QString newSongArea = "5";
    QHash<QString, SectionState> sections;
    QStringList sectionOrder;
    quint64 sectionsGeneration = 0;

  private:
    MusicLibrary *m_store;
    MusicApi::Valid valid(quint64 token, quint64 account);
    void accept(MusicReply result, QString tab, int offset, bool more);
};
