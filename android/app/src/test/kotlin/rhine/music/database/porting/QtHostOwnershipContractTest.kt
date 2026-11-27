package rhine.music.database.porting

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 进程单例所有权 / 构造决策 / 通道归属的纯 JVM 合同自检（MF-D14-2 回归面）。
 *
 * 用到的都是 host 侧不依赖 Android framework 的纯决策 API：
 * QtHostOwnershipRegistry、QtHostInitPlan、planHostInit、shouldInstallChannels。
 * 不需要 Robolectric 或设备，也不 import 任何 android.* 类型。
 *
 * 本原子**没有执行**任何 Gradle/测试命令：此文件是静态交付，断言是否通过由执行方裁决。
 */
class QtHostOwnershipContractTest {

    @Test
    fun planRequestsClaimOnlyForValidReadyActivityInstance() {
        val ready = planHostInit(
            probeVerdict = "ready",
            argErrors = emptyList(),
            activityPresent = true,
        )
        assertTrue(ready.claimRequested)

        // 参数非法：不抢所有权。
        val invalidArgs = planHostInit(
            probeVerdict = "ready",
            argErrors = listOf("argument 'qmlUri' may not be empty or null"),
            activityPresent = true,
        )
        assertFalse(invalidArgs.claimRequested)

        // probe 未 ready（archBlocked/deviceBlocked）：不抢所有权。
        val notReady = planHostInit(
            probeVerdict = "archBlocked",
            argErrors = emptyList(),
            activityPresent = true,
        )
        assertFalse(notReady.claimRequested)

        // ready 但拿不到 Activity：构造必然失败，不许先占坑。
        val noActivity = planHostInit(
            probeVerdict = "ready",
            argErrors = emptyList(),
            activityPresent = false,
        )
        assertFalse(noActivity.claimRequested)
    }

    @Test
    fun secondInstanceIsRejectedWhileFirstStillOwns() {
        val registry = QtHostOwnershipRegistry()
        val first = Any()
        val second = Any()

        assertTrue(registry.claim(first))
        assertFalse(registry.claim(second))
        assertSame(first, registry.current())
    }

    @Test
    fun rejectedSecondInstanceNeverInstallsChannels() {
        // 第二个实例：claim 被尝试但被拒（第一个实例还活着）→ 不得安装通道。
        // 这是 MF-D14-2 的核心：旧的 init 无条件 setMethodCallHandler，会把第一个换掉。
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = true,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = true,
                anotherChannelOwnerExists = true,
            ),
        )
        // 即使登记表一时看不到 owner / 通道 owner，只要 claim 被尝试且失败，也不许装。
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = true,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = false,
            ),
        )
    }

    @Test
    fun diagnosticInstanceInstallsOnlyWhenNoOwnerExists() {
        // probe 未 ready / 没有 Activity 的诊断实例：必须能向 Dart 上报缺失项……
        assertTrue(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = false,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = false,
            ),
        )
        // ……但只要进程里已有 Qt 单例 owner，它就绝不能再装（否则会覆盖 owner 的 handler）。
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = false,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = true,
                anotherChannelOwnerExists = false,
            ),
        )
        // ……已有别的通道 owner（例如前一个诊断实例）时也不能装，否则会互相顶掉；
        // 且先装者的 dispose 会把后装者的通道拆掉。
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = false,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = true,
            ),
        )
    }

    @Test
    fun validOwnerMayTakeOverChannelsFromDiagnosticInstance() {
        // 合法 owner 抢到单例后允许接管通道：诊断实例先前装的 handler 被替换，
        // 诊断实例不再是 channelOwner，它的 dispose 不会拆掉合法 owner 的通道。
        assertTrue(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = true,
                claimGranted = true,
                constructionFailed = false,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = true,
            ),
        )
    }

    @Test
    fun invalidArgsAndConstructionFailureNeverInstallChannels() {
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = false,
                claimAttempted = false,
                claimGranted = false,
                constructionFailed = false,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = false,
            ),
        )
        assertFalse(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = true,
                claimGranted = true,
                constructionFailed = true,
                anotherOwnerExists = false,
                anotherChannelOwnerExists = false,
            ),
        )
        // 正常 owner：装。
        assertTrue(
            shouldInstallChannels(
                argErrorsEmpty = true,
                claimAttempted = true,
                claimGranted = true,
                constructionFailed = false,
                anotherOwnerExists = true,
                anotherChannelOwnerExists = false,
            ),
        )
    }

    @Test
    fun releaseOnFailureLetsALaterInstanceClaim() {
        val registry = QtHostOwnershipRegistry()
        val failed = Any()
        val later = Any()

        assertTrue(registry.claim(failed))
        // QtQuickView 构造失败路径：释放自己，而不是占到 dispose。
        registry.release(failed)
        assertNull(registry.current())

        assertTrue(registry.claim(later))
        assertSame(later, registry.current())
    }

    @Test
    fun releaseIsIdentityCheckedAndDoesNotFreeAnotherOwner() {
        val registry = QtHostOwnershipRegistry()
        val owner = Any()
        val stranger = Any()

        assertTrue(registry.claim(owner))
        // 一个非 owner 的 dispose（例如被拒实例）不能把别人的所有权清掉。
        registry.release(stranger)
        assertSame(owner, registry.current())
    }
}
