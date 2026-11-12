#pragma once
#include <QKeySequence>
#include <QMap>
#include <QObject>
#include <QVector>
#include <functional>
#include <memory>

class Host;
class GlobalShortcutBackend {
  public:
    virtual ~GlobalShortcutBackend() = default;
    virtual void clear() = 0;
    virtual QString add(int id, const QKeySequence &sequence) = 0;
};
std::unique_ptr<GlobalShortcutBackend> createGlobalShortcutBackend(std::function<void(int)> activated);

// Owned by the interface process, including while its window is hidden in the tray.
class GlobalShortcuts : public QObject {
    Q_OBJECT
  public:
    struct Action {
        QString id, label, defaultSequence;
    };
    explicit GlobalShortcuts(Host *host, QObject *parent = nullptr,
                             std::unique_ptr<GlobalShortcutBackend> backend = {});
    ~GlobalShortcuts() override;
    static const QVector<Action> &actions();
    static bool valid(const QKeySequence &sequence);
    static QString normalize(const QString &sequence);
    bool enabled() const {
        return m_enabled;
    }
    QString binding(const QString &id) const;
    QString error(const QString &id) const {
        return m_errors.value(id);
    }
    QString recording() const {
        return m_recording;
    }
    QString message() const {
        return m_message;
    }
    void setEnabled(bool enabled);
    bool setBinding(const QString &id, const QString &sequence);
    void beginRecording(const QString &id);
    void cancelRecording();
    void restoreDefaults();
  signals:
    void changed();
    void activated(QString action);

  protected:
    bool eventFilter(QObject *object, QEvent *event) override;

  private:
    Host *m_host;
    std::unique_ptr<GlobalShortcutBackend> m_backend;
    QMap<QString, QString> m_bindings, m_errors;
    QString m_recording, m_message;
    bool m_enabled = false, m_writing = false, m_waitingRelease = false;
    void reload();
    void save();
    void apply();
};
