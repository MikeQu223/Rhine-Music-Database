#pragma once

#include <QVariantMap>

class QRhiCommandBuffer;
class QQuickWindow;

namespace RhineRender {
void setMetalDiagnosticsEnabled(bool enabled);
void markMetalDiagnosticsRecording(bool recording);
void observeMetalWindow(QQuickWindow *window);
void observeMetalCommands(QRhiCommandBuffer *commands);
void observeMetalInterpolation(void *commandBuffer);
QVariantMap takeMetalDiagnostics();
}
