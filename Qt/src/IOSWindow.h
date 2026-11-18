#pragma once

#include <QtCore/qnamespace.h>
#include <functional>

class Engine;
class QString;
class QWindow;

Qt::ScreenOrientation iosContentOrientation();
void configureIOSWindow(QWindow *window, Engine *backend);
bool shareIOSFile(const QString &path, std::function<void()> finished);
