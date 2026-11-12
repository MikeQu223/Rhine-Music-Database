#pragma once

#include <QUrl>
#include <atomic>
#include <functional>
#include <memory>

class QNetworkAccessManager;

namespace AppleTransitionMedia {
using AllowsUrl = std::function<bool(const QUrl &)>;

std::shared_ptr<const QString> copy(QNetworkAccessManager &network, const QUrl &url,
                                    const AllowsUrl &allowsUrl, int timeoutMs,
                                    const std::atomic_bool &cancelled);
}
