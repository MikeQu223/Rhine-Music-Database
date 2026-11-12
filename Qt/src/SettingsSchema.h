#pragma once
#include <QString>
#include <QStringList>
#include <QVector>

class Host;
class MusicLibrary;

/** 设置项的声明式描述 */
namespace SettingsSchema {
enum class SectionId { Provider, Preferences, Performance, Storage, Update, Project, Footer };
enum class SettingKind { Switch, Choice, Stepper, Slider, TextInput, Action, Link, Custom };
enum class BindingKind { Preference, HudState, Player, External, Capability, Updater, Action, CustomSection };
enum class StorageType {
    None,
    OnOff,
    ReducedFull,
    Theme,
    TrayQuit,
    AppendReplace,
    Integer,
    Enum,
    PlayerQuality,
    PlayerAlternative,
    ExternalBool,
    HudCachedInt,
    HudCachedBool,
    Capability,
    Updater
};

struct SettingChoice {
    QString value;
    QString label;
};

struct SettingsValue {
    StorageType type = StorageType::None;
    QString raw;
    QString canonical;
    bool boolean = false;
    int integer = 0;
    bool valid = false;
    bool isDefault = false;
};

struct SettingsContext {
    Host *host = nullptr;
    MusicLibrary *music = nullptr;
    bool dark = false;
    QString themeMode;
    bool reduced = false;
    bool startupAnimation = false;
    bool discRotation = false;
    bool vsync = true;
    int archiveMaskStrength = 50;
    QString expandedId;
    QString cacheMessage;
};

using Predicate = bool (*)(const SettingsContext &);
using LabelFn = QString (*)(const SettingsContext &, const SettingsValue &);
using ChoicesFn = QVector<SettingChoice> (*)(const SettingsContext &);

struct SettingBinding {
    BindingKind kind = BindingKind::Preference;
    QString preferenceKey;
    QString action;
    QString actionPrefix;
};

struct SettingDescriptor {
    QString id;
    SectionId section = SectionId::Preferences;
    SettingKind kind = SettingKind::Switch;
    SettingBinding binding;
    StorageType storage = StorageType::None;
    int order = 0;
    QString titleEn;
    QString titleZh;
    QString description;
    bool showDescription = false;
    QString actionLabel;
    QString restartHint;
    QString defaultValue;
    QVector<SettingChoice> choices;
    ChoicesFn choicesFor = nullptr;
    int minimum = 0;
    int maximum = 0;
    int step = 0;
    QVector<int> steps;
    bool wrap = false;
    Predicate visible = nullptr;
    Predicate enabled = nullptr;
    LabelFn label = nullptr;
    QString customRenderer;
    double customHeight = 0;
    QString help;
};

struct SettingsSection {
    SectionId id = SectionId::Preferences;
    int number = 1;
    int order = 0;
    QString titleEn;
    QString titleZh;
    QString customRenderer;
    double customHeight = 0;
    Predicate visible = nullptr;
};

const QVector<SettingDescriptor> &descriptors();
const QVector<SettingsSection> &sections();
const SettingDescriptor *find(const QString &id);

SettingsValue read(const SettingDescriptor &descriptor, const SettingsContext &context);
QString displayLabel(const SettingDescriptor &descriptor, const SettingsContext &context);
QVector<SettingChoice> choices(const SettingDescriptor &descriptor, const SettingsContext &context);
bool visible(const SettingDescriptor &descriptor, const SettingsContext &context);
bool enabled(const SettingDescriptor &descriptor, const SettingsContext &context);
QString normalize(const SettingDescriptor &descriptor, const SettingsContext &context, const QString &raw);
QString nextValue(const SettingDescriptor &descriptor, const SettingsContext &context, int direction);
QString switchTarget(const SettingDescriptor &descriptor, const SettingsContext &context);
QStringList validateRegistry();
}
