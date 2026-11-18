#pragma once

#include <QtCore/qnamespace.h>

class Engine;
class QWindow;

Qt::ScreenOrientation iosContentOrientation();
void configureIOSWindow(QWindow *window, Engine *backend);
