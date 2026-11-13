#include "GlobalShortcuts.h"
#include "AppStorage.h"
#include "Host.h"
#include <QCoreApplication>
#include <QKeyEvent>
#include <QTemporaryDir>
#include <QDebug>

namespace {
struct FakeBackend : GlobalShortcutBackend {
    QMap<int, QString> registered;
    QString occupied;
    void clear() override {
        registered.clear();
    }
    QString add(int id, const QKeySequence &sequence) override {
        const auto value = sequence.toString(QKeySequence::PortableText);
        if (value == occupied) {
            return "系统占用";
        }
        registered[id] = value;
        return {};
    }
};
bool check(bool value, const char *message) {
    if (!value) {
        qCritical() << message;
    }
    return value;
}
}
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    QTemporaryDir directory;
    if (!directory.isValid() || !AppStorage::initializePortable(directory.path()).isEmpty()) {
        return 1;
    }
    Host host({}, true);
    host.offline = false; // Credentials remain isolated; preferences live in the temporary store.
    auto backend = std::make_unique<FakeBackend>();
    auto *fake = backend.get();
    GlobalShortcuts keys(&host, nullptr, std::move(backend));
    if (!check(!keys.enabled() && fake->registered.isEmpty(), "Global shortcuts must default to off")) {
        return 1;
    }
    if (!check(!GlobalShortcuts::valid(QKeySequence("A")) &&
                   !GlobalShortcuts::valid(QKeySequence("Ctrl+K, Ctrl+C")) &&
                   !GlobalShortcuts::valid(QKeySequence("F11")) &&
                   GlobalShortcuts::normalize("Alt+Ctrl+Space") == "Ctrl+Alt+Space",
               "Only valid, modified single chords may be registered")) {
        return 1;
    }
    keys.setEnabled(true);
    if (!check(fake->registered.size() == 8, "Enabling must register all defaults")) {
        return 1;
    }
    if (!check(!keys.setBinding("next", "Ctrl+Alt+Left") && !keys.message().isEmpty(),
               "Duplicates must be rejected")) {
        return 1;
    }
    fake->occupied = "Ctrl+Shift+N";
    const auto previous = keys.binding("next");
    if (!check(!keys.setBinding("next", fake->occupied) && keys.binding("next") == previous &&
                   fake->registered.size() == 8,
               "OS conflicts must preserve the previous binding")) {
        return 1;
    }
    keys.beginRecording("next");
    if (!check(fake->registered.isEmpty(), "Recording must suspend native hotkeys")) {
        return 1;
    }
    QKeyEvent override(QEvent::ShortcutOverride, Qt::Key_F11, Qt::NoModifier);
    QCoreApplication::sendEvent(&host, &override);
    if (!check(override.isAccepted(), "Recording must suppress local F11/other shortcuts")) {
        return 1;
    }
    QKeyEvent press(QEvent::KeyPress, Qt::Key_N, Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier);
    QCoreApplication::sendEvent(&host, &press);
    if (!check(keys.recording().isEmpty() && fake->registered.isEmpty(),
               "Native hotkeys must remain suspended until key release")) {
        return 1;
    }
    QKeyEvent release(QEvent::KeyRelease, Qt::Key_N, Qt::NoModifier);
    QCoreApplication::sendEvent(&host, &release);
    if (!check(fake->registered.size() == 8, "Key release must restore native hotkeys")) {
        return 1;
    }
    {
        GlobalShortcuts restored(&host, nullptr, std::make_unique<FakeBackend>());
        if (!check(restored.enabled() && restored.binding("next") == keys.binding("next"),
                   "Custom bindings must survive recreation")) {
            return 1;
        }
    }
    keys.beginRecording("next");
    QKeyEvent escape(QEvent::KeyPress, Qt::Key_Escape, Qt::NoModifier);
    QCoreApplication::sendEvent(&host, &escape);
    if (!check(keys.recording().isEmpty() && fake->registered.size() == 8, "Escape must cancel recording")) {
        return 1;
    }
    keys.beginRecording("next");
    QKeyEvent remove(QEvent::KeyPress, Qt::Key_Delete, Qt::NoModifier);
    QCoreApplication::sendEvent(&host, &remove);
    QCoreApplication::sendEvent(&host, &release);
    if (!check(keys.binding("next").isEmpty() && fake->registered.size() == 7,
               "Delete must clear the binding")) {
        return 1;
    }
    keys.restoreDefaults();
    if (!check(fake->registered.size() == 8 && keys.binding("next") == previous,
               "Reset must restore defaults")) {
        return 1;
    }
    keys.beginRecording("toggle");
    QEvent deactivate(QEvent::ApplicationDeactivate);
    QCoreApplication::sendEvent(&host, &deactivate);
    if (!check(keys.recording().isEmpty() && fake->registered.size() == 8,
               "Losing focus must cancel recording and restore native shortcuts")) {
        return 1;
    }
    keys.setEnabled(false);
    if (!check(fake->registered.isEmpty(), "Disabling must release every registration")) {
        return 1;
    }
    auto first = createGlobalShortcutBackend([](int) {}), second = createGlobalShortcutBackend([](int) {});
    const auto chord = QKeySequence("Ctrl+Alt+Shift+F19");
    if (!check(first && second && first->add(0, chord).isEmpty() && !second->add(1, chord).isEmpty(),
               "Native backends must detect ownership conflicts")) {
        return 1;
    }
    first->clear();
    if (!check(second->add(1, chord).isEmpty(), "Released native bindings must be reusable")) {
        return 1;
    }
    qInfo("Global shortcut capture, conflicts, persistence, reset and native registration passed");
    return 0;
}
