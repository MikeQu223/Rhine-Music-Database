#include "GlobalShortcuts.h"
#import <Carbon/Carbon.h>
#include <QSet>

namespace {
class MacShortcuts final : public GlobalShortcutBackend {
    QVector<EventHotKeyRef> registered;
    EventHandlerRef handler = nullptr;
    QSet<UInt32> pressed;
    std::function<void(int)> activated;
    static OSStatus receive(EventHandlerCallRef, EventRef event, void *context) {
        EventHotKeyID id{};
        const auto status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, nullptr,
                                              sizeof(id), nullptr, &id);
        if (status != noErr || id.signature != 'RHGS') {
            return eventNotHandledErr;
        }
        auto *self = static_cast<MacShortcuts *>(context);
        if (GetEventKind(event) == kEventHotKeyReleased) {
            self->pressed.remove(id.id);
        } else if (!self->pressed.contains(id.id)) {
            self->pressed.insert(id.id);
            self->activated(int(id.id));
        }
        return noErr;
    }
    static int nativeKey(Qt::Key key) {
        if (key == Qt::Key_Space) {
            return kVK_Space;
        }
        switch (key) {
        case Qt::Key_Left:
            return kVK_LeftArrow;
        case Qt::Key_Right:
            return kVK_RightArrow;
        case Qt::Key_Up:
            return kVK_UpArrow;
        case Qt::Key_Down:
            return kVK_DownArrow;
        case Qt::Key_Home:
            return kVK_Home;
        case Qt::Key_End:
            return kVK_End;
        case Qt::Key_PageUp:
            return kVK_PageUp;
        case Qt::Key_PageDown:
            return kVK_PageDown;
        default:
            break;
        }
        static const UInt32 functionKeys[]{kVK_F1,  kVK_F2,  kVK_F3,  kVK_F4,  kVK_F5,  kVK_F6,  kVK_F7,
                                           kVK_F8,  kVK_F9,  kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
                                           kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20};
        if (key >= Qt::Key_F1 && key <= Qt::Key_F20) {
            return int(functionKeys[key - Qt::Key_F1]);
        }
        // Resolve letter/number keys through the current keyboard layout, including non-US layouts.
        TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
        if (!source) {
            return -1;
        }
        const auto data =
            static_cast<CFDataRef>(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData));
        int result = -1;
        if (data) {
            const auto *layout = reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
            for (UInt16 code = 0; code < 128; ++code) {
                UInt32 dead = 0;
                UniChar chars[4]{};
                UniCharCount count = 0;
                if (UCKeyTranslate(layout, code, kUCKeyActionDisplay, 0, LMGetKbdType(),
                                   kUCKeyTranslateNoDeadKeysBit, &dead, 4, &count, chars) == noErr &&
                    count == 1 && QChar(chars[0]).toUpper().unicode() == key) {
                    result = code;
                    break;
                }
            }
        }
        CFRelease(source);
        return result;
    }

  public:
    explicit MacShortcuts(std::function<void(int)> callback) : activated(std::move(callback)) {
        const EventTypeSpec types[]{{kEventClassKeyboard, kEventHotKeyPressed},
                                    {kEventClassKeyboard, kEventHotKeyReleased}};
        InstallApplicationEventHandler(receive, 2, types, this, &handler);
    }
    ~MacShortcuts() override {
        clear();
        if (handler) {
            RemoveEventHandler(handler);
        }
    }
    void clear() override {
        for (auto key : registered) {
            UnregisterEventHotKey(key);
        }
        registered.clear();
        pressed.clear();
    }
    QString add(int id, const QKeySequence &sequence) override {
        if (!handler) {
            return "无法创建系统快捷键接收器";
        }
        const auto combo = sequence[0];
        const auto code = nativeKey(combo.key());
        if (code < 0) {
            return "当前键盘布局不支持此按键";
        }
        UInt32 modifiers = 0;
        const auto mods = combo.keyboardModifiers();
        // Qt maps ControlModifier to Command and MetaModifier to physical Control on macOS.
        if (mods & Qt::ControlModifier) {
            modifiers |= cmdKey;
        }
        if (mods & Qt::MetaModifier) {
            modifiers |= controlKey;
        }
        if (mods & Qt::AltModifier) {
            modifiers |= optionKey;
        }
        if (mods & Qt::ShiftModifier) {
            modifiers |= shiftKey;
        }
        EventHotKeyRef reference = nullptr;
        const EventHotKeyID identifier{'RHGS', UInt32(id)};
        const auto status = RegisterEventHotKey(UInt32(code), modifiers, identifier,
                                                GetApplicationEventTarget(), 0, &reference);
        if (status != noErr) {
            return "此组合被系统保留或其他应用占用";
        }
        registered.append(reference);
        return {};
    }
};
}
std::unique_ptr<GlobalShortcutBackend> createGlobalShortcutBackend(std::function<void(int)> activated) {
    return std::make_unique<MacShortcuts>(std::move(activated));
}
