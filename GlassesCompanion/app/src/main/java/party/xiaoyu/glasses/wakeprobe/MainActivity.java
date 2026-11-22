package party.xiaoyu.glasses.wakeprobe;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.net.Uri;
import android.provider.Settings;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.net.wifi.WifiManager;
import android.speech.SpeechRecognizer;
import android.Manifest;
import android.content.pm.PackageManager;
import android.content.pm.PackageInfo;
import android.content.pm.ProviderInfo;
import android.database.Cursor;
import android.provider.CalendarContract;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.rokid.cxr.CXRServiceBridge;
import com.rokid.cxr.Caps;
import java.nio.charset.StandardCharsets;
import java.net.URL;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.UUID;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONArray;
import org.json.JSONObject;

/** Foreground-only probe: records screen transitions while this process is alive. */
public final class MainActivity extends Activity {
    private static final boolean DIRECT_VOICE_ENABLED = true;
    private TextView label;
    private TextView feederView;
    private TextView homeView;
    private TextView scheduleView;
    private TextView memoView;
    private android.view.View previewRoot;
    private long previewUntil;
    private final Runnable publishPreview = () -> {
        if (this.bridge == null || previewRoot == null || previewRoot.getWidth() <= 0 || previewRoot.getHeight() <= 0
                || android.os.SystemClock.elapsedRealtime() > previewUntil) return;
        try {
            JSONObject data = new JSONObject();
            data.put("width", previewRoot.getWidth()); data.put("height", previewRoot.getHeight());
            JSONArray fields = new JSONArray();
            int[] rootLocation = new int[2]; previewRoot.getLocationOnScreen(rootLocation);
            for (TextView view : new TextView[]{feederView, homeView, scheduleView, memoView, label}) {
                if (view == null || view.getVisibility() != android.view.View.VISIBLE) continue;
                int[] location = new int[2]; view.getLocationOnScreen(location);
                JSONObject field = new JSONObject();
                field.put("x", location[0] - rootLocation[0]); field.put("y", location[1] - rootLocation[1]);
                field.put("width", view.getWidth()); field.put("height", view.getHeight());
                field.put("paddingLeft", view.getCompoundPaddingLeft()); field.put("paddingTop", view.getCompoundPaddingTop());
                field.put("textSize", view.getTextSize()); field.put("color", view.getCurrentTextColor());
                field.put("text", view.getText().toString()); fields.put(field);
            }
            data.put("fields", fields);
            String encoded = android.util.Base64.encodeToString(data.toString().getBytes(StandardCharsets.UTF_8), android.util.Base64.NO_WRAP);
            Caps event = new Caps(); event.write("message"); event.write("GLASSES_PREVIEW:" + encoded);
            this.bridge.sendMessage("rk_custom_key", event);
        } catch (Exception ignored) { }
    };
    private String feederReading = "喂食器\n等待读取";
    private ScheduleMirror scheduleMirror;
    private boolean scheduleReceived;
    private final SystemDataMirror systemDataMirror = new SystemDataMirror();
    private boolean feederRequestRunning;
    private int screenOnCount;
    private int screenOffCount;
    private static volatile CXRServiceBridge processBridge;
    private static volatile MainActivity bridgeOwner;
    private CXRServiceBridge bridge;
    private NativePhotoTransfer nativePhotoTransfer;
    private NativePhotoParallelTransfer nativePhotoParallelTransfer;
    // Diagnostic protocol carries synthetic bytes only; it never accesses photos.
    private int photoLinkSequence;
    private long photoLinkDeadline;
    private final Runnable photoLinkSend = new Runnable() {
        @Override public void run() {
            if (bridge == null || photoLinkSequence >= 32 || android.os.SystemClock.elapsedRealtime() >= photoLinkDeadline) return;
            StringBuilder payload = new StringBuilder("PHOTO_LINK_PROBE:" + photoLinkSequence + ":");
            for (int i = 0; i < 512; i++) payload.append((char) ('A' + i % 26));
            boolean sent = sendVoiceEvent(payload.toString());
            android.util.Log.i("PhotoLinkProbe", "sequence=" + photoLinkSequence + " accepted=" + sent);
            label.postDelayed(this, 3000);
        }
    };
    private String bridgeState = "准备通信";
    private static volatile String connectionState = "手机通信：等待";
    private String directState = "眼镜直连：待检查";
    private String speechState = "眼镜识别：待检查";
    private boolean directProbeRunning;
    private boolean directHomeRunning;
    private boolean wifiEnableFailed;
    private boolean wifiWasConnected;
    private long lastWifiEnableAttempt = -10000;
    private PairingSession pairingSession;
    private final Runnable refreshDirectTimer = new Runnable() {
        @Override public void run() {
            refreshDirectHome();
            if (label != null) label.postDelayed(this, 60000);
        }
    };
    private int messageCount;
    private String reading = "等待家居数据";
    private String voiceId;
    private boolean voiceInProgress;
    private boolean diaryMode;
    private boolean diaryRequestAccepted;
    private int lastMessageResult;
    private static boolean bridgeReinitialized;
    private boolean updateChecking;
    private LanUpdater.Prepared updateReady;
    private int tapCount;
    private final Runnable finishTapSequence = () -> {
        int count = tapCount;
        tapCount = 0;
        if (count == 1 && updateReady != null && !diaryMode) installReadyUpdate();
        else if (count == 1) startVoiceFromGesture();
        else if (count == 2 && !diaryMode) checkForUpdate();
        else if (count == 2) { bridgeState = "连续轻点三次记日记"; updateLabel(); }
    };

    private void handleSingleFingerTap() {
        if (updateChecking) { bridgeState = "更新处理中"; updateLabel(); return; }
        if (voiceInProgress) { bridgeState = diaryMode ? "正在处理日记" : "正在处理语音"; updateLabel(); return; }
        tapCount++;
        label.removeCallbacks(finishTapSequence);
        if (tapCount >= 3) {
            tapCount = 0;
            diaryMode = true;
            startVoiceFromGesture();
        } else {
            bridgeState = "已收到轻点 " + tapCount + "/3";
            updateLabel();
            label.postDelayed(finishTapSequence, 850);
        }
    }
    private boolean voiceAwaitingConfirmation;
    private long voiceExpiresAt;
    private final Runnable releaseVoiceScreen = () -> getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    private void keepScreenForVoice(long milliseconds) {
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        label.removeCallbacks(releaseVoiceScreen);
        label.postDelayed(releaseVoiceScreen, milliseconds);
    }
    private final BroadcastReceiver gestureReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (!"com.android.action.ACTION_TWO_FINGER_SINGLE_TAP".equals(intent.getAction())) return;
            if (!diaryMode && !voiceInProgress) {
                diaryMode = true; bridgeState = "记日记：轻点拍照并说话";
                keepScreenForVoice(100000); updateLabel();
            }
        }
    };

    private void startVoiceFromGesture() {
            if (diaryMode) {
                if (voiceInProgress) { bridgeState = "正在处理日记"; updateLabel(); return; }
                if (bridge == null) { bridgeState = "请先连接手机"; updateLabel(); return; }
                keepScreenForVoice(150000);
                voiceInProgress = true;
                voiceId = UUID.randomUUID().toString();
                diaryRequestAccepted = false;
                final String startedId = voiceId;
                attemptDiaryRequest(startedId, 0);
                label.postDelayed(() -> {
                    if (voiceInProgress && startedId.equals(voiceId)) {
                        voiceInProgress = false; voiceId = null; bridgeState = "手机响应超时，请重试"; updateLabel();
                    }
                }, 150000);
                updateLabel(); return;
            }
            if (DIRECT_VOICE_ENABLED && hasDirectCredential()) { startDirectVoice(); return; }
            if (bridge == null) { bridgeState = "手机连接未就绪"; updateLabel(); return; }
            if (voiceInProgress && !voiceAwaitingConfirmation) { bridgeState = "正在处理语音"; updateLabel(); return; }
            keepScreenForVoice(45000);
            if (voiceAwaitingConfirmation && voiceId != null && System.currentTimeMillis() < voiceExpiresAt) {
                String id = voiceId;
                voiceAwaitingConfirmation = false;
                voiceId = null;
                if (sendVoiceEvent("VOICE_CONFIRM:" + id)) bridgeState = "正在发送";
            } else {
                voiceId = UUID.randomUUID().toString();
                voiceAwaitingConfirmation = false;
                voiceInProgress = true;
                final String startedId = voiceId;
                if (sendVoiceEvent("VOICE_START:" + voiceId)) bridgeState = "等待手机准备语音";
                else voiceInProgress = false;
                label.postDelayed(() -> {
                    if (voiceInProgress && startedId.equals(voiceId)) {
                        voiceInProgress = false;
                        voiceId = null;
                        bridgeState = "语音超时，请重试";
                        updateLabel();
                    }
                }, 45000);
            }
            updateLabel();
    }

    private void attemptDiaryRequest(String id, int attempt) {
        if (!voiceInProgress || !id.equals(voiceId) || diaryRequestAccepted) return;
        boolean sent = sendVoiceEvent("DIARY_START:" + id);
        if (!sent && lastMessageResult == CXRServiceBridge.EFAULT && attempt >= 1 && !bridgeReinitialized) {
            // The SDK exposes no reconnect method. Recreate its client at most
            // once per process and register both channels before retrying.
            bridgeReinitialized = true;
            initializeCxrBridge(true);
        }
        if (attempt < 14) {
            bridgeState = sent ? "等待手机确认日记请求" : "正在重新联系手机 " + (attempt + 1) + "/15";
            label.postDelayed(() -> attemptDiaryRequest(id, attempt + 1), 2000);
        } else {
            voiceInProgress = false; voiceId = null;
            bridgeState = "手机未确认，请打开眼镜家居重连后重试";
            if (!sent && lastMessageResult == CXRServiceBridge.EFAULT) readBridgeErrorCode();
        }
        updateLabel();
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_DPAD_CENTER) {
            if (event.getRepeatCount() == 0) handleSingleFingerTap();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override public boolean onKeyUp(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_ENTER || keyCode == KeyEvent.KEYCODE_DPAD_CENTER) return true;
        return super.onKeyUp(keyCode, event);
    }

    @Override public void onBackPressed() {
        if (updateReady != null) {
            updateReady.file.delete(); updateReady = null;
            bridgeState = "已取消更新"; updateLabel(); return;
        }
        if (diaryMode && !voiceInProgress) {
            diaryMode = false;
            bridgeState = "已返回家居"; updateLabel(); return;
        }
        super.onBackPressed();
    }

    private void checkForUpdate() {
        if (updateChecking || voiceInProgress) return;
        diaryMode = false;
        updateChecking = true; bridgeState = "正在检查 Mac 更新"; updateLabel();
        new Thread(() -> {
            try {
                LanUpdater.Prepared next = new LanUpdater(this).checkAndDownload();
                runOnUiThread(() -> {
                    updateChecking = false;
                    if (next == null) bridgeState = "已经是最新版本";
                    else { if (updateReady != null) updateReady.file.delete(); updateReady = next;
                        bridgeState = "发现 v" + next.version + "，单击安装，返回取消"; keepScreenForVoice(60000); }
                    updateLabel();
                });
            } catch (Exception error) {
                runOnUiThread(() -> { updateChecking = false; bridgeState = "更新检查失败：" + (error.getMessage() == null ? "连接 Mac 失败" : error.getMessage()); updateLabel(); });
            }
        }, "lan-update-check").start();
    }

    private void installReadyUpdate() {
        if (updateReady == null || updateChecking) return;
        if (android.os.Build.VERSION.SDK_INT >= 26 && !getPackageManager().canRequestPackageInstalls()) {
            try {
                bridgeState = "请允许安装更新，返回后单击安装"; updateLabel();
                startActivity(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getPackageName())));
            } catch (Exception error) { bridgeState = "系统未提供安装权限设置"; updateLabel(); }
            return;
        }
        updateChecking = true; bridgeState = "正在准备系统安装确认"; updateLabel();
        LanUpdater.Prepared next = updateReady;
        new Thread(() -> {
            try {
                new LanUpdater(this).install(next);
                runOnUiThread(() -> { updateChecking = false; bridgeState = "请在系统界面确认更新"; updateLabel(); });
            } catch (Exception error) {
                runOnUiThread(() -> { updateChecking = false; bridgeState = "安装未启动：" + (error.getMessage() == null ? "系统错误" : error.getMessage()); updateLabel(); });
            }
        }, "lan-update-install").start();
    }

    private boolean sendVoiceEvent(String message) {
        try {
            Caps event = new Caps();
            event.write("message");
            event.write(message);
            int result = bridge.sendMessage("rk_custom_key", event);
            lastMessageResult = result;
            if (result == 0) return true;
            bridgeState = "联系手机失败 " + result + "，请打开眼镜家居重连";
            return false;
        } catch (Throwable ignored) { }
        bridgeState = "未能联系手机";
        return false;
    }

    // Read only this process's SDK error code, never message payloads or diary text.
    private void readBridgeErrorCode() {
        new Thread(() -> {
            String code = null;
            try {
                Process process = new ProcessBuilder("logcat", "-d", "-t", "150", "--pid=" + android.os.Process.myPid()).redirectErrorStream(true).start();
                java.util.regex.Pattern pattern = java.util.regex.Pattern.compile("sendMessageShort: flora call failed: (-?\\d+)");
                try (java.io.BufferedReader reader = new java.io.BufferedReader(new java.io.InputStreamReader(process.getInputStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        java.util.regex.Matcher match = pattern.matcher(line);
                        if (match.find()) code = match.group(1);
                    }
                }
                process.waitFor();
            } catch (Exception ignored) { }
            final String result = code;
            runOnUiThread(() -> {
                if (!voiceInProgress && bridgeState.startsWith("手机未确认")) {
                    bridgeState = result == null ? "手机未确认，诊断不可用；请重连" : "通信失败 SDK -3 / 内部 " + result;
                    updateLabel();
                }
            });
        }, "bridge-error-code").start();
    }

    private void reportCalendarProviders() {
        try {
            StringBuilder detail = new StringBuilder();
            for (PackageInfo info : getPackageManager().getInstalledPackages(PackageManager.GET_PROVIDERS)) {
                if (info.providers == null) continue;
                for (ProviderInfo provider : info.providers) {
                    String authority = provider.authority == null ? "" : provider.authority;
                    String key = (info.packageName + " " + authority).toLowerCase(java.util.Locale.ROOT);
                    if (!provider.exported || !(key.contains("calendar") || key.contains("schedule"))) continue;
                    if (detail.length() > 0) detail.append("; ");
                    detail.append(authority).append(provider.readPermission == null ? " [无读取权限要求]" : " [受权限保护]");
                    if (detail.length() > 350) break;
                }
                if (detail.length() > 350) break;
            }
            if (detail.length() == 0) detail.append("未发现公开的日程接口");
            if (checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED) {
                try (Cursor calendars = getContentResolver().query(CalendarContract.Calendars.CONTENT_URI,
                             new String[]{CalendarContract.Calendars._ID}, null, null, null);
                     Cursor events = getContentResolver().query(CalendarContract.Events.CONTENT_URI,
                             new String[]{CalendarContract.Events._ID}, null, null, null)) {
                    if (calendars == null || events == null) detail.append("；系统日历查询无响应");
                    else detail.append("；系统日历 ").append(calendars.getCount()).append(" 个，日程 ").append(events.getCount()).append(" 条");
                } catch (Exception ignored) { detail.append("；系统日历查询失败"); }
            } else detail.append("；系统日历未授权");
            sendVoiceEvent("SCHEDULE_PROVIDERS:" + detail);
        } catch (Exception ignored) { sendVoiceEvent("SCHEDULE_PROVIDERS:接口检查失败"); }
    }

    private void reportScheduleChannel() {
        String value = getPreferences(MODE_PRIVATE).getString("schedule_channel_probe", "尚未收到日程通道消息");
        sendVoiceEvent("SCHEDULE_CHANNEL:" + value);
    }

    private static String describeSchedulePayload(Caps args) {
        if (args == null || args.size() < 2) return "无第二项";
        try {
            Caps.Value value = args.at(1);
            if (value.type() == Caps.Value.TYPE_OBJECT) {
                Caps child = value.getObject();
                return "对象项数 " + (child == null ? 0 : child.size());
            }
            if (value.type() == Caps.Value.TYPE_BINARY) {
                Caps.Binary data = value.getBinary();
                return "二进制长度 " + (data == null ? 0 : data.length);
            }
            if (value.type() != Caps.Value.TYPE_STRING) return "类型 " + value.type();
            String s = value.getString();
            if (s == null || s.length() > 65536) return "字符串无效";
            Object root = new org.json.JSONTokener(s).nextValue();
            String kind = "对象";
            if (root instanceof JSONArray) {
                JSONArray array = (JSONArray) root;
                kind = "数组 " + array.length();
                root = array.length() == 0 ? null : array.opt(0);
            }
            if (!(root instanceof JSONObject)) return kind + "，内容类型 " + (root == null ? "空" : root.getClass().getSimpleName());
            java.util.Iterator<String> keys = ((JSONObject) root).keys();
            StringBuilder names = new StringBuilder();
            while (keys.hasNext() && names.length() < 110) {
                String key = keys.next();
                if (!key.matches("[A-Za-z_][A-Za-z0-9_]{0,31}")) continue;
                if (names.length() > 0) names.append(",");
                names.append(key);
            }
            return kind + "字段 " + names;
        } catch (Exception ignored) { return "非 JSON 字符串或无法解析"; }
    }

    private void startDirectVoice() {
        if (voiceInProgress) { bridgeState = "正在处理语音"; updateLabel(); return; }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, 42);
            bridgeState = "请允许麦克风权限，再轻点说话"; updateLabel(); return;
        }
        final String token;
        try { token = GlassCredential.load(this); }
        catch (Exception error) { bridgeState = "直连凭据不可用"; updateLabel(); return; }
        if (token == null) return;
        voiceInProgress = true;
        keepScreenForVoice(60000);
        bridgeState = "正在准备语音"; updateLabel();
        new Thread(() -> {
            AudioRecord record = null;
            try {
                int min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
                if (min <= 0) throw new IllegalStateException("microphone unavailable");
                record = new AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, 8192));
                if (record.getState() != AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("microphone unavailable");
                record.startRecording();
                if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) throw new IllegalStateException("microphone unavailable");
                runOnUiThread(() -> { bridgeState = "请说话"; updateLabel(); });
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] buffer = new byte[3200];
                boolean heard = false;
                long silentSamples = 0;
                long absoluteSum = 0, sampleCount = 0;
                int peak = 0;
                long start = android.os.SystemClock.elapsedRealtime();
                while (android.os.SystemClock.elapsedRealtime() - start < 7000 && bytes.size() < 224000) {
                    int n = record.read(buffer, 0, buffer.length);
                    if (n <= 0) throw new IllegalStateException("microphone read failed");
                    n -= n % 2; bytes.write(buffer, 0, n);
                    long total = 0;
                    for (int i = 0; i < n; i += 2) {
                        int amplitude = Math.abs((int)(short)((buffer[i] & 255) | (buffer[i + 1] << 8)));
                        total += amplitude;
                        peak = Math.max(peak, amplitude);
                    }
                    absoluteSum += total;
                    sampleCount += n / 2;
                    if (total / Math.max(1, n / 2) >= 50) { heard = true; silentSamples = 0; }
                    else if (heard) silentSamples += n / 2;
                    if (heard && silentSamples >= 19200 && bytes.size() >= 32000) break;
                }
                record.stop(); record.release(); record = null;
                if (!heard) throw new IllegalStateException("no speech detected " + (absoluteSum / Math.max(1, sampleCount)) + "/" + peak);
                byte[] pcm = bytes.toByteArray();
                if (peak > 0 && peak < 4000) {
                    int gain = Math.min(10, 10000 / peak);
                    for (int i = 0; i + 1 < pcm.length; i += 2) {
                        int sample = (short)((pcm[i] & 255) | (pcm[i + 1] << 8));
                        sample = Math.max(-32768, Math.min(32767, sample * gain));
                        pcm[i] = (byte) sample; pcm[i + 1] = (byte) (sample >> 8);
                    }
                }
                runOnUiThread(() -> { bridgeState = "正在识别"; updateLabel(); });
                DirectHomeClient direct = new DirectHomeClient();
                String text = direct.transcribe(token, pcm);
                if (text.isEmpty()) throw new IllegalStateException("no speech recognized");
                runOnUiThread(() -> { bridgeState = "识别：" + text; updateLabel(); });
                DirectHomeClient.ForwardOutcome outcome = direct.forwardXiaoai(token, text);
                runOnUiThread(() -> {
                    bridgeState = outcome == DirectHomeClient.ForwardOutcome.FORWARDED ? "已发送：" + text :
                            outcome == DirectHomeClient.ForwardOutcome.REJECTED ? "指令未发送" : "发送结果未知，请勿重复";
                    voiceInProgress = false; label.removeCallbacks(releaseVoiceScreen); releaseVoiceScreen.run(); updateLabel();
                });
            } catch (Exception error) {
                String message = error.getMessage() == null ? "" : error.getMessage();
                final String detail;
                if (error instanceof SecurityException) detail = "麦克风权限被拒绝";
                else if (message.equals("microphone unavailable")) detail = "眼镜麦克风无法启动";
                else if (message.equals("microphone read failed")) detail = "眼镜麦克风读取失败";
                else if (message.startsWith("no speech detected ")) detail = "音量均/峰 " + message.substring("no speech detected ".length());
                else if (message.equals("no speech recognized")) detail = "收到音频但未识别出语音";
                else if (message.matches("recognition unavailable: HTTP [0-9]{3}")) detail = message.replace("recognition unavailable: ", "识别服务 ");
                else if (error instanceof java.net.UnknownHostException) detail = "语音域名解析失败";
                else if (error instanceof java.net.SocketTimeoutException) detail = "语音连接超时";
                else if (error instanceof javax.net.ssl.SSLException) detail = "语音安全连接失败";
                else detail = "语音错误 " + error.getClass().getSimpleName();
                runOnUiThread(() -> { bridgeState = detail; voiceInProgress = false;
                    label.removeCallbacks(releaseVoiceScreen); releaseVoiceScreen.run(); updateLabel(); });
            } finally {
                if (record != null) { try { record.stop(); } catch (Exception ignored) { } record.release(); }
            }
        }, "direct-glasses-voice").start();
    }

    private final BroadcastReceiver screenReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (Intent.ACTION_SCREEN_ON.equals(intent.getAction())) {
                screenOnCount++;
                ensureWifiEnabled();
                if (!hasDirectCredential()) probeDirectAccess();
                refreshDirectHome();
                refreshFeeder();
                if (bridge != null && !hasDirectCredential()) {
                    try {
                        Caps event = new Caps();
                        event.write("message");
                        event.write("HOME_SCREEN_ON");
                        int result = bridge.sendMessage("rk_custom_key", event);
                        if (result == 0) {
                            bridgeState = "已请求更新";
                            final int count = messageCount;
                            final int wake = screenOnCount;
                            label.postDelayed(() -> {
                                if (count == messageCount && wake == screenOnCount) {
                                    bridgeState = "显示上次读数";
                                    updateLabel();
                                }
                            }, 10000);
                        } else {
                            bridgeState = "请求更新失败 " + result;
                        }
                    } catch (Throwable ignored) { }
                }
            }
            if (Intent.ACTION_SCREEN_OFF.equals(intent.getAction())) screenOffCount++;
            updateLabel();
        }
    };

    private final BroadcastReceiver wifiReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            NetworkInfo wifi = manager == null ? null : manager.getNetworkInfo(ConnectivityManager.TYPE_WIFI);
            boolean connected = wifi != null && wifi.isConnected();
            if (connected && !wifiWasConnected) {
                wifiEnableFailed = false;
                refreshDirectHome();
                refreshFeeder();
            }
            wifiWasConnected = connected;
            if (!connected && WifiManager.WIFI_STATE_CHANGED_ACTION.equals(intent.getAction())) refreshDirectHome();
        }
    };

    /** Ask the OS to enable Wi-Fi on launch/wake; saved network selection remains with the OS. */
    private void ensureWifiEnabled() {
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi == null) { wifiEnableFailed = true; return; }
        try {
            int state = wifi.getWifiState();
            if (state == WifiManager.WIFI_STATE_ENABLED || state == WifiManager.WIFI_STATE_ENABLING) {
                wifiEnableFailed = false;
                return;
            }
            long now = android.os.SystemClock.elapsedRealtime();
            if (now - lastWifiEnableAttempt < 10000) return;
            lastWifiEnableAttempt = now;
            wifiEnableFailed = !wifi.setWifiEnabled(true);
        } catch (SecurityException | IllegalStateException error) { wifiEnableFailed = true; }
    }

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().setBackgroundDrawable(new ColorDrawable(Color.BLACK));
        getWindow().setStatusBarColor(Color.BLACK);
        getWindow().setNavigationBarColor(Color.BLACK);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(10, 8, 10, 8);
        root.setBackgroundColor(Color.BLACK);
        LinearLayout columns = new LinearLayout(this);
        columns.setOrientation(LinearLayout.HORIZONTAL);
        feederView = new TextView(this);
        feederView.setTextColor(0xff80e6c8);
        feederView.setTextSize(14);
        feederView.setGravity(Gravity.TOP | Gravity.START);
        feederView.setPadding(0, 0, 8, 0);
        homeView = new TextView(this);
        homeView.setTextColor(0xffd7ffe9);
        homeView.setTextSize(14);
        homeView.setGravity(Gravity.TOP | Gravity.START);
        scheduleView = new TextView(this);
        scheduleView.setTextColor(0xffd7ffe9);
        scheduleView.setTextSize(14);
        scheduleView.setGravity(Gravity.TOP | Gravity.START);
        memoView = new TextView(this);
        memoView.setTextColor(0xffd7ffe9);
        memoView.setTextSize(14);
        memoView.setMaxLines(2);
        memoView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        memoView.setGravity(Gravity.TOP | Gravity.START);
        LinearLayout leftColumn = new LinearLayout(this);
        leftColumn.setOrientation(LinearLayout.VERTICAL);
        leftColumn.addView(feederView, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        leftColumn.addView(scheduleView, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        leftColumn.addView(memoView, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        columns.addView(leftColumn, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        columns.addView(homeView, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        root.addView(columns, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
        label = new TextView(this);
        label.setTextSize(11);
        label.setTextColor(0xff00ff00);
        label.setGravity(Gravity.START);
        root.addView(label, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        setContentView(root);
        previewRoot = root;
        String savedSchedule = getPreferences(MODE_PRIVATE).getString("rokid_schedule_mirror", null);
        scheduleMirror = new ScheduleMirror(savedSchedule);
        scheduleReceived = savedSchedule != null;
        systemDataMirror.acceptMemos("Memo_Sync", getPreferences(MODE_PRIVATE).getString("rokid_memo_mirror", null));
        speechState = DIRECT_VOICE_ENABLED && !CompanionEndpoints.HOME_URL.isEmpty() ? "语音识别：NAS 本地" :
                (SpeechRecognizer.isRecognitionAvailable(this) ? "眼镜识别：系统服务可用" : "眼镜识别：未发现系统服务");
        if (!hasDirectCredential()) probeDirectAccess();
        refreshFeeder();
        reading = getPreferences(MODE_PRIVATE).getString("last_reading", "等待家居数据");
        label.post(refreshDirectTimer);
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        registerReceiver(screenReceiver, filter);
        IntentFilter wifiFilter = new IntentFilter();
        wifiFilter.addAction(WifiManager.WIFI_STATE_CHANGED_ACTION);
        wifiFilter.addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION);
        registerReceiver(wifiReceiver, wifiFilter);
        IntentFilter voiceFilter = new IntentFilter();
        voiceFilter.addAction("com.android.action.ACTION_TWO_FINGER_SINGLE_TAP");
        registerReceiver(gestureReceiver, voiceFilter);
        initializeCxrBridge(false);
    }

    private void initializeCxrBridge(boolean reconnect) {
        bridgeOwner = this;
        try {
            boolean create = processBridge == null || reconnect;
            if (create) {
                processBridge = createProcessBridge();
            }
            bridge = processBridge;
            bridgeState = "等待手机消息";
            android.util.Log.i("LeqiCxr", create ? "companion subscribed" : "companion reused subscription");
        } catch (RuntimeException | LinkageError error) {
            bridgeState = "通信初始化失败";
            android.util.Log.w("LeqiCxr", "companion subscription failed: " + error.getClass().getSimpleName());
        }
        updateLabel();
    }

    private static CXRServiceBridge createProcessBridge() {
        // The native subscriptions outlive an Activity. One process bridge routes
        // callbacks only to the current screen when Android recreates it.
        CXRServiceBridge shared = new CXRServiceBridge();
        shared.setStatusListener(new CXRServiceBridge.StatusListener() {
            @Override public void onConnected(String a, String b, int type) {
                if (processBridge != null && processBridge != shared) return;
                connectionState = "手机通信：已连接";
                MainActivity owner = bridgeOwner;
                if (owner != null) owner.runOnUiThread(owner::onPhoneConnected);
            }
            @Override public void onDisconnected() {
                if (processBridge == shared) updateConnectionState("手机通信：已断开");
            }
            @Override public void onConnecting(String a, String b, int type) {
                if (processBridge == shared) updateConnectionState("手机通信：连接中");
            }
            @Override public void onARTCStatus(float value, boolean connected) { }
            @Override public void onRokidAccountChanged(String account) {
                MainActivity owner = bridgeOwner;
                if (processBridge == shared && owner != null) owner.runOnUiThread(() -> {
                    if (bridgeOwner == owner) owner.clearSystemData();
                });
            }
        });
        int schedule = shared.subscribe("Schedule", (CXRServiceBridge.MsgCallback) (name, args, bytes) -> {
            if (processBridge != shared) return;
            MainActivity owner = bridgeOwner;
            if (owner != null) owner.receiveSchedule(args, bytes);
        });
        // Memo support is optional on older device software. Keep the existing
        // bridge operational when the host does not accept this subscription.
        try {
            shared.subscribe("Memo", (CXRServiceBridge.MsgCallback) (name, args, bytes) -> {
                MainActivity owner = bridgeOwner;
                if (processBridge == shared && owner != null) owner.receiveMemos(args);
            });
        } catch (RuntimeException | LinkageError ignored) { }
        int custom = shared.subscribe("rk_custom_client", (CXRServiceBridge.MsgCallback) (name, args, bytes) -> {
            if (processBridge != shared) return;
            MainActivity owner = bridgeOwner;
            if (owner != null) owner.receiveCustomMessage(args, bytes);
        });
        if (schedule != 0 || custom != 0) throw new IllegalStateException("CXR channels " + schedule + " / " + custom);
        return shared;
    }

    private static void updateConnectionState(String state) {
        connectionState = state;
        MainActivity owner = bridgeOwner;
        if (owner != null) owner.runOnUiThread(() -> {
            if (bridgeOwner == owner) owner.updateLabel();
        });
    }

    private void onPhoneConnected() {
        if (bridgeOwner != this) return;
        reportCalendarProviders();
        reportScheduleChannel();
        try {
            if (hasDirectCredential()) { refreshDirectHome(); updateLabel(); return; }
            Caps event = new Caps();
            event.write("message");
            event.write("HOME_SCREEN_ON");
            int result = bridge.sendMessage("rk_custom_key", event);
            bridgeState = result == 0 ? "已请求更新" : "请求更新失败 " + result;
        } catch (Throwable ignored) { bridgeState = "请求更新异常"; }
        updateLabel();
    }

    private void receiveSchedule(Caps args, byte[] bytes) {
        int count = args == null ? 0 : args.size();
        int length = bytes == null ? 0 : bytes.length;
        String command = "其他";
        try {
            if (count > 0 && args.at(0).type() == Caps.Value.TYPE_STRING) {
                String first = args.at(0).getString();
                if (first != null && first.matches("Schedule_(Sync|Add|Remove)")) command = first;
            }
        } catch (Exception ignored) { }
        String diagnostic = command + "，数据项 " + count + "，字节 " + length + "，" + describeSchedulePayload(args);
        String payload = null;
        try {
            if (count > 1 && args.at(1).type() == Caps.Value.TYPE_STRING) payload = args.at(1).getString();
        } catch (Exception ignored) { }
        final String scheduleCommand = command, schedulePayload = payload;
        runOnUiThread(() -> {
            if (bridgeOwner != this) return;
            boolean accepted = scheduleMirror != null && scheduleMirror.accept(scheduleCommand, schedulePayload);
            if (accepted) {
                scheduleReceived = true;
                getPreferences(MODE_PRIVATE).edit().putString("rokid_schedule_mirror", scheduleMirror.serialize()).apply();
                updateLabel();
            }
            String outcome = scheduleMirror == null || schedulePayload == null ? "无可解析数据" : scheduleMirror.diagnostic(schedulePayload, accepted, System.currentTimeMillis());
            getPreferences(MODE_PRIVATE).edit().putString("schedule_channel_probe", diagnostic + "；" + outcome).apply();
            reportScheduleChannel();
        });
    }

    private void clearSystemData() {
        scheduleMirror = new ScheduleMirror(null);
        scheduleReceived = false;
        systemDataMirror.clear();
        getPreferences(MODE_PRIVATE).edit()
                .remove("rokid_schedule_mirror").remove("rokid_memo_mirror").remove("schedule_channel_probe").apply();
        updateLabel();
    }

    private void receiveMemos(Caps args) {
        if (args == null || args.size() < 2) return;
        try {
            if (args.at(0).type() != Caps.Value.TYPE_STRING || args.at(1).type() != Caps.Value.TYPE_STRING) return;
            String command = args.at(0).getString();
            String payload = args.at(1).getString();
            runOnUiThread(() -> {
                if (bridgeOwner == this && systemDataMirror.acceptMemos(command, payload)) {
                    getPreferences(MODE_PRIVATE).edit().putString("rokid_memo_mirror", systemDataMirror.savedMemos()).apply();
                    android.util.Log.i("LeqiOrganizerSync", "Memo snapshot received");
                    updateLabel();
                }
            });
        } catch (RuntimeException ignored) { }
    }

    private void receiveCustomMessage(Caps args, byte[] bytes) {
        String message = bytes == null ? "" : findMessage(new String(bytes, StandardCharsets.UTF_8));
        if (message.isEmpty()) message = findInCaps(args, 0);
        final String received = message;
        final String diagnostic = "未识别 内容项 " + (args == null ? "无" : args.size()) + " 字节 " + (bytes == null ? 0 : bytes.length);
        runOnUiThread(() -> {
            if (bridgeOwner != this) return;
            messageCount++;
            if (received.startsWith(SystemDataMirror.REQUEST)) {
                String reply = systemDataMirror.reply(received, scheduleMirror, scheduleReceived);
                boolean sent = reply != null && sendVoiceEvent(reply);
                android.util.Log.i("LeqiOrganizerSync", "Reader request valid=" + (reply != null)
                        + " sent=" + sent + " transport=" + (reply == null ? "not-sent" : lastMessageResult));
                return;
            } else if ((received.startsWith("PHOTO_NATIVE_PARALLEL:") || received.startsWith("PHOTO_NATIVE_BENCH:") || received.startsWith("PHOTO_ALBUM_NEXT:"))) {
                if (nativePhotoParallelTransfer == null) nativePhotoParallelTransfer = new NativePhotoParallelTransfer(MainActivity.this,
                        response -> runOnUiThread(() -> sendVoiceEvent(response)));
                nativePhotoParallelTransfer.start(received.replaceAll("[^a-zA-Z0-9_:.\\-].*", ""));
            } else if (received.startsWith("PHOTO_NATIVE_ARM:")) {
                if (nativePhotoTransfer == null) nativePhotoTransfer = new NativePhotoTransfer(MainActivity.this,
                        response -> runOnUiThread(() -> sendVoiceEvent(response)));
                nativePhotoTransfer.arm(received.replaceAll("[^a-zA-Z0-9_:.\\-].*", ""));
            } else if (received.startsWith("PHOTO_NATIVE_FETCH:")) {
                if (nativePhotoTransfer != null) nativePhotoTransfer.fetch(received.replaceAll("[^a-zA-Z0-9_:.\\-].*", ""));
            } else if (received.startsWith("PHOTO_NET_PROBE:")) {
                String[] parts = received.split(":");
                if (parts.length >= 4 && parts[1].matches("(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.).*")
                        && parts[2].matches("[0-9]{1,5}") && parts[3].matches("[a-f0-9]{32}")) {
                    final String host = parts[1], token = parts[3];
                    final int port = Integer.parseInt(parts[2]);
                    new Thread(() -> {
                        try (java.net.Socket socket = new java.net.Socket()) {
                            socket.connect(new java.net.InetSocketAddress(host, port), 5000);
                            java.io.OutputStream out = socket.getOutputStream();
                            out.write((token + "\n").getBytes(StandardCharsets.US_ASCII));
                            byte[] block = new byte[1024]; java.util.Arrays.fill(block, (byte) 65);
                            for (int i = 0; i < 64; i++) out.write(block);
                            out.flush(); android.util.Log.i("PhotoLinkProbe", "local synthetic stream sent");
                        } catch (Exception e) { android.util.Log.i("PhotoLinkProbe", "local stream error=" + e.getClass().getSimpleName()); }
                    }, "photo-net-probe").start();
                }
            } else if (received.startsWith("PHOTO_LINK_START")) {
                label.removeCallbacks(photoLinkSend); photoLinkSequence = 0;
                photoLinkDeadline = android.os.SystemClock.elapsedRealtime() + 60000;
                label.post(photoLinkSend);
            } else if (received.startsWith("PHOTO_LINK_ACK:")) {
                try {
                    String digits = received.substring("PHOTO_LINK_ACK:".length()).replaceAll("[^0-9].*", "");
                    android.util.Log.i("PhotoLinkProbe", "ack=" + digits);
                    if (Integer.parseInt(digits) == photoLinkSequence) {
                        label.removeCallbacks(photoLinkSend); photoLinkSequence++;
                        if (photoLinkSequence < 32) label.post(photoLinkSend);
                    }
                } catch (Exception ignored) { }
            } else if (received.startsWith("UPDATE_CHECK")) {
                checkForUpdate();
            } else if (received.startsWith("PREVIEW_START")) {
                previewUntil = android.os.SystemClock.elapsedRealtime() + 120000;
                updateLabel();
            } else if (received.startsWith("PREVIEW_STOP")) {
                previewUntil = 0; label.removeCallbacks(publishPreview);
            } else if (received.startsWith("PAIR_OFFER:")) {
                String[] parts = received.split(":", 3);
                try {
                    pairingSession = new PairingSession(parts[1], parts[2]);
                    bridgeState = "配对码 " + pairingSession.code + " · 请在手机核对";
                    sendVoiceEvent("PAIR_KEY:" + pairingSession.id + ":" + pairingSession.publicKey);
                    keepScreenForVoice(120000);
                } catch (Exception error) { pairingSession = null; bridgeState = "配对请求无效"; }
            } else if (received.startsWith("PAIR_SECRET:")) {
                String[] parts = received.split(":", 4);
                try {
                    if (pairingSession == null) throw new IllegalStateException("no pairing");
                    String token = pairingSession.decrypt(parts[1], parts[2], parts[3]);
                    GlassCredential.save(MainActivity.this, token);
                    pairingSession = null;
                    sendVoiceEvent("PAIR_OK:" + parts[1]);
                    bridgeState = "配对完成";
                    refreshDirectHome();
                } catch (Exception error) { pairingSession = null; bridgeState = "配对失败，请重试"; }
            } else if (received.startsWith("HOME_JSON:")) {
                if (hasDirectCredential()) return;
                try {
                    reading = formatHome(new JSONObject(received.substring("HOME_JSON:".length())));
                    getPreferences(MODE_PRIVATE).edit().putString("last_reading", reading).apply();
                    bridgeState = "已更新";
                } catch (Exception ignored) { bridgeState = "家居数据格式异常"; }
            } else if (received.startsWith("HOME:")) {
                if (hasDirectCredential()) return;
                reading = received.substring(5);
                getPreferences(MODE_PRIVATE).edit().putString("last_reading", reading).apply();
                bridgeState = "已更新";
            } else if (received.startsWith("VOICE_CONFIRM_REQUEST:")) {
                String content = received.substring("VOICE_CONFIRM_REQUEST:".length());
                int separator = content.indexOf(':');
                if (separator > 0 && content.substring(0, separator).equals(voiceId)) {
                    reading = content.substring(separator + 1);
                    voiceAwaitingConfirmation = true;
                    voiceExpiresAt = System.currentTimeMillis() + 30000;
                    keepScreenForVoice(30000);
                    bridgeState = "双指单击确认发送";
                    final String confirmationId = voiceId;
                    label.postDelayed(() -> {
                        if (voiceAwaitingConfirmation && confirmationId.equals(voiceId)
                                && System.currentTimeMillis() >= voiceExpiresAt) {
                            voiceAwaitingConfirmation = false;
                            voiceId = null;
                            reading = getPreferences(MODE_PRIVATE).getString("last_reading", "等待家居数据");
                            bridgeState = "确认已过期";
                            updateLabel();
                        }
                    }, 30100);
                }
            } else if (received.startsWith("DIARY_ACCEPT:")) {
                String accepted = received.substring("DIARY_ACCEPT:".length()).trim();
                if (voiceInProgress && voiceId != null && accepted.startsWith(voiceId)) {
                    diaryRequestAccepted = true;
                    bridgeState = "手机已接收，正在准备日记";
                }
            } else if (received.startsWith("DIARY_EXIT")) {
                diaryMode = false; voiceInProgress = false; voiceId = null;
                bridgeState = "已退出日记";
            } else if (received.startsWith("DIARY_STATUS:")) {
                bridgeState = received.substring("DIARY_STATUS:".length());
                if (!bridgeState.equals("正在拍照") && !bridgeState.equals("已交给手机，等待自己记")
                        && !bridgeState.contains("继续语音")) {
                    voiceInProgress = false; voiceId = null;
                    label.removeCallbacks(releaseVoiceScreen); releaseVoiceScreen.run();
                }
            } else if (received.startsWith("VOICE_RESULT:")) {
                reading = received.substring("VOICE_RESULT:".length());
                bridgeState = "识别完成，正在发送";
            } else if (received.startsWith("VOICE_STATUS:")) {
                bridgeState = received.substring("VOICE_STATUS:".length());
                if (!bridgeState.equals("正在连接语音") && !bridgeState.equals("请说话")
                        && !bridgeState.equals("正在发送给小爱")) {
                    voiceInProgress = false;
                    voiceId = null;
                    label.removeCallbacks(releaseVoiceScreen);
                    releaseVoiceScreen.run();
                }
            } else { bridgeState = diagnostic; }
            updateLabel();
        });
    }

    private static String findMessage(String text) {
        if (text == null) return "";
        int start = -1;
        for (String prefix : new String[]{SystemDataMirror.REQUEST, "PHOTO_ALBUM_NEXT:", "PHOTO_NATIVE_PARALLEL:", "PHOTO_NATIVE_BENCH:", "PHOTO_NATIVE_ARM:", "PHOTO_NATIVE_FETCH:", "PHOTO_NET_PROBE:", "PHOTO_LINK_START", "PHOTO_LINK_ACK:", "UPDATE_CHECK", "PREVIEW_START", "PREVIEW_STOP", "PAIR_OFFER:", "PAIR_SECRET:", "HOME_JSON:", "HOME:", "VOICE_CONFIRM_REQUEST:", "VOICE_RESULT:", "VOICE_STATUS:", "DIARY_ACCEPT:", "DIARY_STATUS:", "DIARY_EXIT"}) {
            int candidate = text.indexOf(prefix);
            if (candidate >= 0 && (start < 0 || candidate < start)) start = candidate;
        }
        return start >= 0 ? text.substring(start).replace("\u0000", "").trim() : "";
    }

    private static String value(JSONObject data, String key) {
        if (!data.has(key) || data.isNull(key)) return "--";
        String value = data.optString(key, "").trim();
        return value.isEmpty() || value.equals("unknown") || value.equals("unavailable") ? "--" : value;
    }

    private static String formatHome(JSONObject data) {
        StringBuilder text = new StringBuilder();
        text.append("卧室 ").append(value(data, "temperature")).append("°  ").append(value(data, "humidity")).append("%")
            .append("\neTVOC ").append(value(data, "tvoc"))
            .append("\n客厅 ").append(value(data, "living_temperature")).append("°  ").append(value(data, "living_humidity")).append("%");
        if ("工作中".equals(value(data, "washer_status"))) {
            text.append("\n洗衣 ").append(value(data, "washer_remaining")).append(" 分钟");
        } else if ("estimated_waiting".equals(value(data, "washer_waiting"))) {
            String minutes = value(data, "washer_waiting_minutes");
            if (!"--".equals(minutes)) text.append("\n衣物待取约 ").append(minutes).append("分");
        }
        if ("on".equals(value(data, "footbath_power"))) {
            text.append("\n泡脚 ").append(value(data, "footbath_temperature")).append("°");
        }
        String heater = HeaterDisplay.format(value(data, "heater_state"), value(data, "heater_current"),
                value(data, "heater_target"), value(data, "heater_mode"));
        if (!heater.isEmpty()) text.append("\n").append(heater);
        if ("工作中".equals(value(data, "cooker_status"))) {
            String stage = value(data, "cooker_pressure_stage");
            if ("--".equals(stage)) stage = value(data, "cooker_stage");
            if ("--".equals(stage)) stage = value(data, "cooker_status");
            text.append("\n压力锅 ").append(stage);
            String remaining = value(data, "cooker_remaining");
            if (!"--".equals(remaining)) text.append(" 剩").append(remaining).append("分");
        }
        if (!"--".equals(value(data, "updated_at"))) text.append("\n更新 ").append(value(data, "updated_at"));
        return text.toString();
    }

    private void probeDirectAccess() {
        if (CompanionEndpoints.HOME_URL.isEmpty()) {
            directState = "眼镜直连：未配置";
            updateLabel();
            return;
        }
        if (directProbeRunning) return;
        ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo active = manager == null ? null : manager.getActiveNetworkInfo();
        if (active == null || !active.isConnected() || active.getType() != ConnectivityManager.TYPE_WIFI) {
            directState = "眼镜直连：未连接 Wi-Fi";
            updateLabel();
            return;
        }
        directProbeRunning = true;
        directState = "眼镜直连：检测中";
        updateLabel();
        new Thread(() -> {
            String result = "眼镜直连：连接失败";
            HttpsURLConnection connection = null;
            try {
                connection = (HttpsURLConnection) new URL(CompanionEndpoints.HOME_URL + "/v1/status").openConnection();
                connection.setConnectTimeout(6000);
                connection.setReadTimeout(6000);
                connection.setInstanceFollowRedirects(false);
                int code = connection.getResponseCode();
                if (code == 401) {
                    InputStream stream = connection.getErrorStream();
                    byte[] buffer = new byte[512];
                    int length = stream == null ? -1 : stream.read(buffer);
                    if (stream != null) stream.close();
                    if (length > 0 && "unauthorized".equals(new JSONObject(new String(buffer, 0, length, StandardCharsets.UTF_8)).optString("error"))) {
                        result = "眼镜直连：家居服务可达";
                    } else result = "眼镜直连：认证响应异常";
                } else result = "眼镜直连：HTTP " + code;
            } catch (Exception ignored) { }
            finally { if (connection != null) connection.disconnect(); }
            final String status = result;
            runOnUiThread(() -> { directProbeRunning = false; directState = status; updateLabel(); });
        }, "direct-network-probe").start();
    }

    private boolean hasDirectCredential() {
        if (CompanionEndpoints.HOME_URL.isEmpty()) return false;
        try { return GlassCredential.load(this) != null; }
        catch (Exception ignored) { return false; }
    }

    private void refreshDirectHome() {
        if (CompanionEndpoints.HOME_URL.isEmpty() || directHomeRunning) return;
        ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        NetworkInfo wifi = manager == null ? null : manager.getNetworkInfo(ConnectivityManager.TYPE_WIFI);
        if (wifi == null || !wifi.isConnected()) {
            WifiManager controller = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            int state = controller == null ? WifiManager.WIFI_STATE_UNKNOWN : controller.getWifiState();
            if (wifiEnableFailed) directState = "眼镜直连：系统未允许打开 Wi-Fi";
            else if (state == WifiManager.WIFI_STATE_ENABLING) directState = "眼镜直连：正在打开 Wi-Fi";
            else if (state == WifiManager.WIFI_STATE_ENABLED) directState = "眼镜直连：等待 Wi-Fi 连接";
            else directState = "眼镜直连：Wi-Fi 未打开";
            updateLabel();
            return;
        }
        final String token;
        try { token = GlassCredential.load(this); }
        catch (Exception error) { directState = "眼镜直连：凭据不可用"; updateLabel(); return; }
        if (token == null) return;
        directHomeRunning = true;
        new Thread(() -> {
            try {
                String next = formatHome(DirectHomeClient.dashboard(new DirectHomeClient().fetchStatus(token)));
                runOnUiThread(() -> {
                    reading = next;
                    getPreferences(MODE_PRIVATE).edit().putString("last_reading", next).apply();
                    directState = "眼镜直连：已更新";
                    directHomeRunning = false;
                    updateLabel();
                });
            } catch (Exception error) {
                final String detail;
                if (error instanceof java.net.UnknownHostException) detail = "域名解析失败";
                else if (error instanceof java.net.SocketTimeoutException) detail = "连接超时";
                else if (error instanceof javax.net.ssl.SSLException) detail = "安全连接失败";
                else if (error instanceof java.net.ConnectException) detail = "无法连接服务";
                else if (error.getMessage() != null && error.getMessage().matches("HTTP [0-9]{3}")) detail = error.getMessage();
                else detail = error.getClass().getSimpleName();
                runOnUiThread(() -> {
                    directState = "眼镜直连：" + detail + "，显示上次读数";
                    directHomeRunning = false;
                    updateLabel();
                });
            }
        }, "direct-home-refresh").start();
    }

    private void refreshFeeder() {
        if (CompanionEndpoints.FEEDER_URL.isEmpty()) {
            feederReading = "喂食器\n未配置";
            updateLabel();
            return;
        }
        if (feederRequestRunning) return;
        feederRequestRunning = true;
        new Thread(() -> {
            String result = "喂食器\n暂时无法读取";
            HttpsURLConnection connection = null;
            try {
                connection = (HttpsURLConnection) new URL(CompanionEndpoints.FEEDER_URL).openConnection();
                connection.setConnectTimeout(6000);
                connection.setReadTimeout(6000);
                connection.setInstanceFollowRedirects(false);
                if (connection.getResponseCode() != 200) throw new java.io.IOException("feeder unavailable");
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                try (InputStream stream = connection.getInputStream()) {
                    byte[] buffer = new byte[1024]; int length;
                    while ((length = stream.read(buffer)) != -1) {
                        if (bytes.size() + length > 32768) throw new java.io.IOException("response too large");
                        bytes.write(buffer, 0, length);
                    }
                }
                JSONObject data = new JSONObject(new String(bytes.toByteArray(), StandardCharsets.UTF_8));
                if (!data.optBoolean("status_available", false)) {
                    result = "喂食器\n状态不可用";
                } else {
                    JSONArray schedule = data.optJSONArray("schedule");
                    JSONArray events = data.optJSONArray("event_times");
                    int planned = schedule == null ? 0 : schedule.length();
                    String eventsCount = data.has("event_count") && !data.isNull("event_count") ? data.optString("event_count") : "--";
                    StringBuilder text = new StringBuilder("喂食器\n计划 ").append(planned).append(" 次\n今日出粮 ").append(eventsCount).append(" 次");
                    long now = System.currentTimeMillis();
                    if (schedule != null) for (int i = 0; i < schedule.length(); i++) {
                        String item = schedule.optString(i, "");
                        try {
                            long scheduled = LocalDate.now().atTime(LocalTime.parse(item)).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli();
                            boolean done = false;
                            if (events != null) for (int j = 0; j < events.length(); j++) {
                                try {
                                    long event = OffsetDateTime.parse(events.optString(j)).toInstant().toEpochMilli();
                                    if (Math.abs(event - scheduled) <= 45L * 60L * 1000L) { done = true; break; }
                                } catch (Exception ignored) { }
                            }
                            text.append(i % 2 == 0 ? "\n" : "  ").append(item).append(done ? " ✓" : scheduled <= now ? " !" : " ·");
                        } catch (Exception ignored) { }
                    }
                    result = text.toString();
                }
            } catch (Exception ignored) { }
            finally { if (connection != null) connection.disconnect(); }
            final String value = result;
            runOnUiThread(() -> { feederRequestRunning = false; feederReading = value; updateLabel(); });
        }, "feeder-network").start();
    }

    private static String findInCaps(Caps caps, int depth) {
        if (caps == null || depth > 3) return "";
        for (int i = 0; i < caps.size(); i++) {
            Caps.Value value = caps.at(i);
            String result = "";
            if (value.type() == Caps.Value.TYPE_STRING) result = findMessage(value.getString());
            else if (value.type() == Caps.Value.TYPE_BINARY) {
                Caps.Binary binary = value.getBinary();
                if (binary != null && binary.data != null) result = findMessage(new String(binary.data, binary.offset, binary.length, StandardCharsets.UTF_8));
            } else if (value.type() == Caps.Value.TYPE_OBJECT) result = findInCaps(value.getObject(), depth + 1);
            if (!result.isEmpty()) return result;
        }
        return "";
    }

    private void updateLabel() {
        String schedule = scheduleMirror == null ? "" : scheduleMirror.display(System.currentTimeMillis(), ZoneId.systemDefault()).trim();
        feederView.setText(diaryMode ? "记日记\n轻点一次开始" : feederReading);
        homeView.setText(diaryMode ? "拍照后说日记\n请等待提示" : "家居\n" + reading);
        scheduleView.setVisibility(diaryMode || schedule.isEmpty() ? android.view.View.GONE : android.view.View.VISIBLE);
        scheduleView.setText(schedule);
        String memo = systemDataMirror.memoPreview();
        memoView.setVisibility(diaryMode || memo.isEmpty() ? android.view.View.GONE : android.view.View.VISIBLE);
        memoView.setText(memo);
        label.setText(bridgeState + "  " + connectionState + "\n" + directState + "  " + speechState + "\n小米同学 · v0.34");
        if (previewUntil > android.os.SystemClock.elapsedRealtime()) {
            label.removeCallbacks(publishPreview); label.postDelayed(publishPreview, 300);
        }
    }

    @Override protected void onResume() {
        super.onResume();
        if (checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED
                && !getPreferences(MODE_PRIVATE).getBoolean("calendar_probe_requested", false)) {
            getPreferences(MODE_PRIVATE).edit().putBoolean("calendar_probe_requested", true).apply();
            requestPermissions(new String[]{Manifest.permission.READ_CALENDAR}, 43);
        }
        ensureWifiEnabled();
        refreshDirectHome();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == 43 && bridge != null) reportCalendarProviders();
    }

    @Override protected void onPause() {
        label.removeCallbacks(finishTapSequence); tapCount = 0;
        super.onPause();
    }

    @Override protected void onDestroy() {
        if (bridgeOwner == this) bridgeOwner = null;
        label.removeCallbacks(photoLinkSend);
        label.removeCallbacks(finishTapSequence);
        label.removeCallbacks(publishPreview);
        label.removeCallbacks(refreshDirectTimer);
        label.removeCallbacks(releaseVoiceScreen);
        unregisterReceiver(screenReceiver);
        unregisterReceiver(wifiReceiver);
        unregisterReceiver(gestureReceiver);
        super.onDestroy();
    }
}
