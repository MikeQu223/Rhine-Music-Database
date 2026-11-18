#include "GlobalShortcuts.h"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

namespace {
class WindowsShortcuts final : public GlobalShortcutBackend {
    HWND window = nullptr;
    QVector<int> registered;
    std::function<void(int)> activated;
    static LRESULT CALLBACK procedure(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        if (message == WM_NCCREATE) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                              LONG_PTR(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams));
        }
        auto *self = reinterpret_cast<WindowsShortcuts *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (self && message == WM_HOTKEY) {
            self->activated(int(wparam) - 0x6000);
            return 0;
        }
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }

  public:
    explicit WindowsShortcuts(std::function<void(int)> callback) : activated(std::move(callback)) {
        WNDCLASSW type{};
        type.lpfnWndProc = procedure;
        type.hInstance = GetModuleHandleW(nullptr);
        type.lpszClassName = L"RhineGlobalShortcuts";
        RegisterClassW(&type);
        window = CreateWindowExW(0, type.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 type.hInstance, this);
    }
    ~WindowsShortcuts() override {
        clear();
        if (window) {
            DestroyWindow(window);
        }
    }
    void clear() override {
        for (const auto id : registered) {
            UnregisterHotKey(window, id);
        }
        registered.clear();
        if (window) {
            MSG message{};
            while (PeekMessageW(&message, window, WM_HOTKEY, WM_HOTKEY, PM_REMOVE)) {
            }
        }
    }
    QString add(int id, const QKeySequence &sequence) override {
        if (!window) {
            return "无法创建系统快捷键接收器";
        }
        const auto combo = sequence[0];
        const auto key = combo.key();
        UINT code = 0, modifiers = MOD_NOREPEAT;
        if ((key >= Qt::Key_A && key <= Qt::Key_Z) || (key >= Qt::Key_0 && key <= Qt::Key_9)) {
            code = UINT(key);
        } else if (key >= Qt::Key_F1 && key <= Qt::Key_F20) {
            code = VK_F1 + key - Qt::Key_F1;
        } else {
            switch (key) {
            case Qt::Key_Space:
                code = VK_SPACE;
                break;
            case Qt::Key_Left:
                code = VK_LEFT;
                break;
            case Qt::Key_Right:
                code = VK_RIGHT;
                break;
            case Qt::Key_Up:
                code = VK_UP;
                break;
            case Qt::Key_Down:
                code = VK_DOWN;
                break;
            case Qt::Key_Home:
                code = VK_HOME;
                break;
            case Qt::Key_End:
                code = VK_END;
                break;
            case Qt::Key_PageUp:
                code = VK_PRIOR;
                break;
            case Qt::Key_PageDown:
                code = VK_NEXT;
                break;
            default:
                return "不支持此按键";
            }
        }
        const auto mods = combo.keyboardModifiers();
        if (mods & Qt::ControlModifier) {
            modifiers |= MOD_CONTROL;
        }
        if (mods & Qt::AltModifier) {
            modifiers |= MOD_ALT;
        }
        if (mods & Qt::ShiftModifier) {
            modifiers |= MOD_SHIFT;
        }
        if (mods & Qt::MetaModifier) {
            modifiers |= MOD_WIN;
        }
        if (!RegisterHotKey(window, 0x6000 + id, modifiers, code)) {
            return "此组合被系统或其他应用占用";
        }
        registered.append(0x6000 + id);
        return {};
    }
};
}
std::unique_ptr<GlobalShortcutBackend> createGlobalShortcutBackend(std::function<void(int)> activated) {
    return std::make_unique<WindowsShortcuts>(std::move(activated));
}
