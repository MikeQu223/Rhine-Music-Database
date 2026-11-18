#include "GlobalShortcuts.h"
#include "Host.h"
#include "PlatformFeatures.h"
#include <QCoreApplication>
#include <QEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QScopedValueRollback>
#include <QTimer>

#if !defined(Q_OS_WIN) && !defined(Q_OS_MACOS)
std::unique_ptr<GlobalShortcutBackend> createGlobalShortcutBackend(std::function<void(int)>) {
    return {};
}
#endif

const QVector<GlobalShortcuts::Action> &GlobalShortcuts::actions() {
    static const QVector<Action> values{{"toggle", "播放 / 暂停", "Ctrl+Alt+Space"},
                                        {"prev", "上一首", "Ctrl+Alt+Left"},
                                        {"next", "下一首", "Ctrl+Alt+Right"},
                                        {"volume-up", "音量加", "Ctrl+Alt+Up"},
                                        {"volume-down", "音量减", "Ctrl+Alt+Down"},
                                        {"like", "喜欢 / 取消喜欢", "Ctrl+Alt+L"},
                                        {"lyrics", "打开 / 关闭桌面歌词", "Ctrl+Alt+R"},
                                        {"window", "显示 / 隐藏主窗口", "Ctrl+Alt+M"}};
    return values;
}
bool GlobalShortcuts::valid(const QKeySequence &sequence) {
    if (sequence.isEmpty()) {
        return true;
    }
    if (sequence.count() != 1) {
        return false;
    }
    const auto combination = sequence[0];
    const auto modifiers = combination.keyboardModifiers();
    const auto key = combination.key();
    const bool supportedKey =
        (key >= Qt::Key_A && key <= Qt::Key_Z) || (key >= Qt::Key_0 && key <= Qt::Key_9) ||
        (key >= Qt::Key_F1 && key <= Qt::Key_F20) || key == Qt::Key_Space || key == Qt::Key_Left ||
        key == Qt::Key_Right || key == Qt::Key_Up || key == Qt::Key_Down || key == Qt::Key_Home ||
        key == Qt::Key_End || key == Qt::Key_PageUp || key == Qt::Key_PageDown;
    return supportedKey && (modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) &&
           !(modifiers & ~(Qt::ControlModifier | Qt::AltModifier | Qt::ShiftModifier | Qt::MetaModifier));
}
QString GlobalShortcuts::normalize(const QString &text) {
    if (text.isEmpty()) {
        return {};
    }
    const auto sequence = QKeySequence::fromString(text, QKeySequence::PortableText);
    return valid(sequence) && !sequence.isEmpty() ? sequence.toString(QKeySequence::PortableText) : QString();
}
GlobalShortcuts::GlobalShortcuts(Host *host, QObject *parent, std::unique_ptr<GlobalShortcutBackend> backend)
    : QObject(parent), m_host(host), m_backend(std::move(backend)) {
    if (!m_backend && PlatformFeatures::GlobalShortcuts && !host->offline) {
        m_backend = createGlobalShortcutBackend([this](int id) {
            QMetaObject::invokeMethod(
                this,
                [this, id] {
                    if (m_enabled && m_recording.isEmpty() && !m_waitingRelease && id >= 0 &&
                        id < actions().size()) {
                        emit activated(actions()[id].id);
                    }
                },
                Qt::QueuedConnection);
        });
    }
    reload();
    QCoreApplication::instance()->installEventFilter(this);
    connect(host, &Host::preferenceChanged, this, [this](const QString &key, const QString &) {
        if (!m_writing && (key == "global-shortcuts" || key == "global-shortcuts-enabled")) {
            reload();
        }
    });
}
GlobalShortcuts::~GlobalShortcuts() {
    QCoreApplication::instance()->removeEventFilter(this);
}
void GlobalShortcuts::reload() {
    const auto object = QJsonDocument::fromJson(m_host->preference("global-shortcuts").toUtf8()).object();
    m_bindings.clear();
    for (const auto &action : actions()) {
        const auto value = object.value(action.id);
        m_bindings[action.id] =
            value.isString() && (value.toString().isEmpty() || !normalize(value.toString()).isEmpty())
                ? normalize(value.toString())
                : action.defaultSequence;
    }
    m_enabled = PlatformFeatures::GlobalShortcuts && m_host->preference("global-shortcuts-enabled") == "on";
    apply();
    emit changed();
}
void GlobalShortcuts::apply() {
    m_errors.clear();
    if (!m_backend) {
        return;
    }
    m_backend->clear();
    if (!m_enabled || !m_recording.isEmpty() || m_waitingRelease) {
        return;
    }
    QMap<QString, QString> used;
    for (int i = 0; i < actions().size(); ++i) {
        const auto &action = actions()[i];
        const auto value = m_bindings.value(action.id);
        if (value.isEmpty()) {
            continue;
        }
        if (used.contains(value)) {
            m_errors[action.id] = "与“" + used.value(value) + "”重复";
        } else {
            used.insert(value, action.label);
            const auto result =
                m_backend->add(i, QKeySequence::fromString(value, QKeySequence::PortableText));
            if (!result.isEmpty()) {
                m_errors[action.id] = result;
            }
        }
    }
}
QString GlobalShortcuts::binding(const QString &id) const {
    return QKeySequence::fromString(m_bindings.value(id), QKeySequence::PortableText)
        .toString(QKeySequence::NativeText);
}
void GlobalShortcuts::save() {
    QScopedValueRollback writing(m_writing, true);
    QJsonObject object;
    for (auto it = m_bindings.cbegin(); it != m_bindings.cend(); ++it) {
        object[it.key()] = it.value();
    }
    m_host->setPreference("global-shortcuts",
                          QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact)));
    m_host->setPreference("global-shortcuts-enabled", m_enabled ? "on" : "off");
    emit changed();
}
void GlobalShortcuts::setEnabled(bool enabled) {
    cancelRecording();
    m_enabled = PlatformFeatures::GlobalShortcuts && enabled;
    apply();
    save();
}
bool GlobalShortcuts::setBinding(const QString &id, const QString &text) {
    if (!m_bindings.contains(id)) {
        return false;
    }
    const auto normalized = normalize(text);
    if (!text.isEmpty() && normalized.isEmpty()) {
        m_message = "请组合 Ctrl / Alt / Command 等修饰键与字母、数字、方向键、空格或 F1–F20";
        emit changed();
        return false;
    }
    for (const auto &action : actions()) {
        if (action.id != id && !normalized.isEmpty() && m_bindings.value(action.id) == normalized) {
            m_message = "此快捷键已用于“" + action.label + "”";
            emit changed();
            return false;
        }
    }
    const auto previous = m_bindings.value(id);
    m_bindings[id] = normalized;
    const auto recording = m_recording;
    m_recording.clear();
    apply();
    const auto registrationError = m_errors.value(id);
    if (!registrationError.isEmpty()) {
        m_bindings[id] = previous;
        m_recording = recording;
        apply();
        m_message = registrationError + "；原绑定已保留";
        emit changed();
        return false;
    }
    m_message.clear();
    save();
    return true;
}
void GlobalShortcuts::beginRecording(const QString &id) {
    if (!m_bindings.contains(id)) {
        return;
    }
    m_waitingRelease = false;
    m_recording = id;
    m_message.clear();
    apply();
    emit changed();
}
void GlobalShortcuts::cancelRecording() {
    m_recording.clear();
    m_message.clear();
    m_waitingRelease = false;
    apply();
    emit changed();
}
void GlobalShortcuts::restoreDefaults() {
    cancelRecording();
    for (const auto &action : actions()) {
        m_bindings[action.id] = action.defaultSequence;
    }
    apply();
    save();
}
bool GlobalShortcuts::eventFilter(QObject *, QEvent *event) {
    if (event->type() == QEvent::ApplicationDeactivate && (!m_recording.isEmpty() || m_waitingRelease)) {
        cancelRecording();
        return false;
    }
    if (m_waitingRelease && event->type() == QEvent::KeyRelease) {
        m_waitingRelease = false;
        apply();
        emit changed();
        return true;
    }
    if (m_recording.isEmpty()) {
        return false;
    }
    if (event->type() == QEvent::ShortcutOverride) {
        event->accept();
        return true;
    }
    if (event->type() != QEvent::KeyPress && event->type() != QEvent::KeyRelease) {
        return false;
    }
    const auto *key = static_cast<QKeyEvent *>(event);
    if (event->type() == QEvent::KeyRelease || key->isAutoRepeat()) {
        return true;
    }
    if (key->key() == Qt::Key_Escape) {
        cancelRecording();
        return true;
    }
    if (key->key() == Qt::Key_Control || key->key() == Qt::Key_Shift || key->key() == Qt::Key_Alt ||
        key->key() == Qt::Key_Meta) {
        return true;
    }
    const bool clear = (key->key() == Qt::Key_Backspace || key->key() == Qt::Key_Delete) &&
                       key->modifiers() == Qt::NoModifier;
    const auto sequence = clear ? QString()
                                : QKeySequence(QKeyCombination(key->modifiers(), Qt::Key(key->key())))
                                      .toString(QKeySequence::PortableText);
    const auto action = m_recording;
    if (setBinding(action, sequence)) {
        m_waitingRelease = true;
        if (m_backend) {
            m_backend->clear();
        }
    }
    return true;
}
