package rhine.music.database.porting

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * SETTINGS-161：设置通道安装/卸载所有权的纯 JVM 合同（无 android.*，无 Robolectric）。
 *
 * 钉住 159 的两个真实反例：
 *  - install 侧：同一 messenger 才复用，否则必须新建（旧闭包/provider 不能被迁移）。
 *  - uninstall 侧：请求者 null / owner 未知 / 非当前 owner 一律 fail-closed，
 *    绝不能"猜着拆当前 owner"（installA;installB;oldA.onDestroy → 不得拆 B）。
 *
 * 只测决策函数；handler 真正挂/摘由编译字节码与设备门另行验证。
 */
class BasicSettingsChannelOwnershipTest {

    private val messengerA = Any()
    private val messengerB = Any()
    private val installedChannel = Any()

    @Test
    fun reuseOnlyForSameInstalledMessenger() {
        assertTrue(settingsChannelReusesInstall(installedChannel, messengerA, messengerA))
        assertFalse(settingsChannelReusesInstall(installedChannel, messengerA, messengerB))
        assertFalse(settingsChannelReusesInstall(null, messengerA, messengerA))
    }

    @Test
    fun nothingInstalledIgnoresEveryRequest() {
        assertEquals(
            SettingsChannelTeardown.NOT_INSTALLED,
            settingsChannelTeardown(null, null, null),
        )
        assertEquals(
            SettingsChannelTeardown.NOT_INSTALLED,
            settingsChannelTeardown(null, messengerA, messengerA),
        )
    }

    @Test
    fun nullRequestNeverTearsDownCurrentOwner() {
        // 反例：旧 Activity 在 engine 已 detach 时 onDestroy 只能拿到 null；它必须 no-op。
        assertEquals(
            SettingsChannelTeardown.NO_MESSENGER,
            settingsChannelTeardown(installedChannel, messengerB, null),
        )
    }

    @Test
    fun unknownOwnerFailsClosed() {
        assertEquals(
            SettingsChannelTeardown.UNKNOWN_OWNER,
            settingsChannelTeardown(installedChannel, null, messengerA),
        )
    }

    @Test
    fun oldOwnerCannotTearDownNewOwner() {
        assertEquals(
            SettingsChannelTeardown.OTHER_OWNER,
            settingsChannelTeardown(installedChannel, messengerB, messengerA),
        )
    }

    @Test
    fun exactCurrentOwnerDetaches() {
        assertEquals(
            SettingsChannelTeardown.DETACH,
            settingsChannelTeardown(installedChannel, messengerB, messengerB),
        )
    }
}
