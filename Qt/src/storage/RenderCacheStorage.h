#pragma once
#include "storage/StorageCoordinator.h"
#include <memory>

class QLockFile;

class RenderCacheStorage {
  public:
    RenderCacheStorage();
    ~RenderCacheStorage();
    QJsonArray scheduleClear();
    QJsonArray stats() const;

  private:
    QString m_root;
    std::unique_ptr<QLockFile> m_lock;
    bool m_ownsCache = false;
};
