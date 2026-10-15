package com.xiongjian.dianbo

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

/**
 * 连续授时音频引擎。
 *
 * Flutter 预编码包络；专用工作线程持有唯一 AudioTrack，按累计采样数生成
 * 正弦载波。帧边界仅改变包络数据，不停止、不重新预备播放器。
 * AudioTimestamp 的单调时间用于估算每个采样实际输出的 UTC 时刻。
 */
class SignalAudioEngine(context: Context, callback: (Map<String, Any>) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val executor = Executors.newSingleThreadExecutor()
    private var callback: ((Map<String, Any>) -> Unit)? = callback
    @Volatile private var session: Session? = null
    @Volatile private var closed = false

    private data class Plan(val baseMicros: Long, val levels: ByteArray)

    /** 每次发波独占的配置与生命周期，避免旧线程释放新会话资源。 */
    private class Session(
        val plan: AtomicReference<Plan>,
        val frequency: Double,
        val frameSeconds: Int,
        val continuous: Boolean,
        val utcMicros: Long,
        val monoNanos: Long,
        val startUtcMicros: Long,
        initialVolume: Float,
    ) {
        val running = AtomicBoolean(true)
        val firstFullFrameUtcMicros = (startUtcMicros + frameSeconds * 1_000_000L - 1) /
            (frameSeconds * 1_000_000L) * (frameSeconds * 1_000_000L)
        val singleEndUtcMicros = firstFullFrameUtcMicros + frameSeconds * 1_000_000L
        @Volatile var volume = initialVolume
        @Volatile var track: AudioTrack? = null
        var focusRequest: AudioFocusRequest? = null
        var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    }

    /** MethodChannel 始终在主线程进入，PCM 计算与阻塞写入交给音频工作线程。 */
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "clock" -> result.success(System.nanoTime())
                "start" -> start(call, result)
                "stop" -> { stop(); result.success(null) }
                "volume" -> {
                    val volume = (call.arguments as? Number)?.toFloat()
                    require(volume != null && volume.isFinite()) { "音量参数无效" }
                    session?.volume = volume.coerceIn(0f, 1f)
                    result.success(null)
                }
                "updatePlan" -> {
                    session?.plan?.set(readPlan(call))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("AUDIO_ARGUMENT", error.message ?: "音频参数无效", null)
        }
    }

    private fun readPlan(call: MethodCall): Plan {
        val base = call.argument<Number>("planBaseUtcMicros")?.toLong()
        val levels = call.argument<ByteArray>("levels")
        require(base != null && base % 60_000_000L == 0L) { "时间码起点无效" }
        require(levels != null && levels.isNotEmpty() && levels.size <= 360_000 && levels.size % 6000 == 0) { "时间码长度无效" }
        require(levels.all { it.toInt() in 0..2 }) { "时间码电平无效" }
        return Plan(base, levels)
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        check(!closed) { "音频引擎已关闭" }
        check(session?.running?.get() != true) { "已有发波会话" }
        val plan = readPlan(call)
        val protocol = call.argument<String>("protocol")
        require(protocol == "bpc" || protocol == "jjy") { "未知授时协议" }
        val frequency = call.argument<Number>("frequency")?.toDouble()
        require(frequency != null && frequency.isFinite() && frequency in 1000.0..20000.0) { "音频频率无效" }
        val utc = call.argument<Number>("clockUtcMicros")?.toLong()
        val mono = call.argument<Number>("clockMonoNanos")?.toLong()
        val volume = call.argument<Number>("volume")?.toFloat()
        require(utc != null && mono != null && volume != null && volume.isFinite()) { "音频时钟无效" }
        val nowMono = System.nanoTime()
        require(nowMono - mono in 0L..5_000_000_000L) { "音频时钟已过期" }
        val nowUtc = utc + (nowMono - mono) / 1000L
        val frameSeconds = if (protocol == "bpc") 20 else 60
        val frameMicros = frameSeconds * 1_000_000L
        // 立即发波，从当前码元接入；接收器会自行寻找下一个帧标记。
        require(nowUtc >= plan.baseMicros && nowUtc + 2 * frameMicros < plan.baseMicros + plan.levels.size * TICK_MICROS) { "时间码计划未覆盖发波区间" }
        val current = Session(AtomicReference(plan), frequency, frameSeconds,
            call.argument<Boolean>("continuous") ?: true, utc, mono, nowUtc, volume.coerceIn(0f, 1f))
        if (!requestFocus(current)) {
            result.error("AUDIO_FOCUS", "无法获得音频焦点，请停止其他音频后重试", null)
            return
        }
        session = current
        executor.execute { stream(current) }
        result.success(null)
    }

    /** 不强制修改系统音量；失去音频焦点时终止发波，避免被系统压低后继续冒充正常授时。 */
    private fun requestFocus(current: Session): Boolean {
        val manager = audioManager ?: return false
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            if (change < 0 && session === current) {
                stop("音频被其他应用打断，请重新开始")
            }
        }
        current.focusListener = listener
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes())
                .setOnAudioFocusChangeListener(listener, main)
                .setAcceptsDelayedFocusGain(false)
                .build()
            current.focusRequest = request
            manager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            (manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
                == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        }
    }

    private fun attributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private fun utcAt(current: Session, monoNanos: Long): Long =
        current.utcMicros + (monoNanos - current.monoNanos) / 1000L

    /**
     * 单个 AudioTrack 贯穿全部帧。写入采用 WRITE_BLOCKING，正确处理部分写入，
     * 保持载波相位与采样计数连续；发现欠载则显式终止，避免发送漂移时间码。
     */
    private fun stream(current: Session) {
        var track: AudioTrack? = null
        var failure: String? = null
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val minimum = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "设备不支持 48 kHz PCM" }
            val bufferBytes = max(minimum, RATE / 10 * 2)
            track = AudioTrack.Builder()
                .setAudioAttributes(attributes())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            check(track.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack 初始化失败" }
            current.track = track
            if (!current.running.get()) return
            // 预填平滑起音的载波，避免为了等硬件时间戳而让用户先听一段静音。
            var phase = 0.0
            val phaseDelta = current.frequency / RATE
            var gain = 0.0
            val prefill = ShortArray(track.bufferSizeInFrames)
            for (i in prefill.indices) {
                gain += (1.0 - gain) * 0.12
                prefill[i] = (sin(phase * 2 * PI) * gain * current.volume * 30000).toInt().toShort()
                phase += phaseDelta
                if (phase >= 1.0) phase -= 1.0
            }
            val prefilled = track.write(prefill, 0, prefill.size, AudioTrack.WRITE_BLOCKING)
            check(prefilled == prefill.size) { "无法完整预填音频缓冲" }
            var written = prefilled.toLong()
            track.play()
            val timestamp = AudioTimestamp()
            var frameZeroNanos: Long? = null
            val calibrationDeadline = System.nanoTime() + 2_000_000_000L
            var lastReport = 0L
            var lastLog = 0L
            var initialUnderruns: Int? = null
            var endFrame: Long? = null
            val block = ShortArray(BLOCK_FRAMES)
            while (current.running.get()) {
                if (written < RATE / 2 || frameZeroNanos == null) {
                    if (track.getTimestamp(timestamp) && timestamp.nanoTime > 0) {
                        frameZeroNanos = timestamp.nanoTime - timestamp.framePosition * 1_000_000_000L / RATE
                    }
                }
                val zero = frameZeroNanos
                val calibrated = zero != null && written >= RATE / 2
                check(calibrated || System.nanoTime() < calibrationDeadline) { "无法锁定音频输出时钟" }
                val zeroUtc = if (zero == null) 0L else utcAt(current, zero)
                val plan = current.plan.get()
                for (i in block.indices) {
                    val utcMicros = zeroUtc + (written + i) * 1_000_000L / RATE
                    val withinSignal = calibrated && (current.continuous || utcMicros < current.singleEndUtcMicros)
                    var target = if (calibrated) 0.0 else 1.0
                    if (withinSignal) {
                        val index = (utcMicros - plan.baseMicros) / TICK_MICROS
                        check(index in 0L until plan.levels.size.toLong()) { "时间码计划已过期" }
                        target = when (plan.levels[index.toInt()].toInt()) {
                            1 -> 1.0
                            0 -> 0.316227766 // -10 dB 功率对应的振幅比，不能直接用 0.1 代替。
                            else -> 0.0
                        }
                    }
                    // 亚毫秒平滑避免包络边沿产生强可听爆音；不改变 10 ms 码元网格。
                    gain += (target - gain) * 0.12
                    block[i] = (sin(phase * 2 * PI) * gain * current.volume * 30000).toInt().toShort()
                    phase += phaseDelta
                    if (phase >= 1.0) phase -= 1.0
                }
                var offset = 0
                while (offset < block.size && current.running.get()) {
                    val count = track.write(block, offset, block.size - offset, AudioTrack.WRITE_BLOCKING)
                    check(count > 0) { "PCM 写入失败：$count" }
                    offset += count
                }
                written += offset
                if (calibrated && initialUnderruns == null) initialUnderruns = track.underrunCount
                if (calibrated && initialUnderruns != null) {
                    check(track.underrunCount == initialUnderruns) { "音频缓冲欠载，请重新开始" }
                }
                val now = System.nanoTime()
                if (now - lastReport >= 100_000_000L) {
                    lastReport = now
                    val playUtc = utcAt(current, now)
                    val elapsed = playUtc - current.firstFullFrameUtcMicros
                    val state = if (calibrated) "running" else "calibrating"
                    val status = mapOf<String, Any>("state" to state,
                        "frames" to max(0L, elapsed / (current.frameSeconds * 1_000_000L)),
                        "startUtcMicros" to current.startUtcMicros,
                        "playUtcMicros" to playUtc,
                        "underruns" to max(0, track.underrunCount - (initialUnderruns ?: track.underrunCount)),
                        "clockLocked" to calibrated, "frequency" to current.frequency,
                        "writtenFrames" to written, "trackId" to track.audioSessionId)
                    emit(current, status)
                    if (now - lastLog >= 1_000_000_000L) {
                        lastLog = now
                        Log.i(TAG, status.toString())
                    }
                }
                if (calibrated && !current.continuous && endFrame == null) {
                    endFrame = (current.singleEndUtcMicros - zeroUtc) * RATE / 1_000_000L
                }
                val end = endFrame
                if (end != null && (track.playbackHeadPosition.toLong() and 0xffffffffL) >= end) break
            }
        } catch (error: Exception) {
            if (current.running.get()) {
                failure = error.message ?: "音频输出失败"
                Log.e(TAG, failure, error)
            }
        } finally {
            current.running.set(false)
            current.track = null
            try { track?.stop() } catch (_: IllegalStateException) { }
            track?.release()
            main.post {
                abandonFocus(current)
                emit(current, mapOf("state" to if (failure == null) "stopped" else "error",
                    "message" to (failure ?: "发波结束")))
            }
        }
    }

    private fun emit(current: Session, value: Map<String, Any>) {
        main.post {
            if (!closed && session === current) callback?.invoke(value)
        }
    }

    private fun abandonFocus(current: Session) {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            current.focusRequest?.let { manager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            current.focusListener?.let { manager.abandonAudioFocus(it) }
        }
    }

    /** 主线程只取消标记并暂停，以唤醒阻塞写入；释放由拥有 AudioTrack 的线程执行。 */
    fun stop(message: String = "已停止发波") {
        val current = session ?: return
        current.running.set(false)
        try { current.track?.pause() } catch (_: IllegalStateException) { }
        abandonFocus(current)
        emit(current, mapOf("state" to "stopped", "message" to message))
    }

    /** Activity 销毁时解除回调并关闭工作线程，不持有 Activity 引用。 */
    fun close() {
        stop()
        closed = true
        callback = null
        executor.shutdown()
    }

    private companion object {
        const val TAG = "DianboSignal"
        const val RATE = 48000
        const val BLOCK_FRAMES = 480
        const val TICK_MICROS = 10000L
    }
}
