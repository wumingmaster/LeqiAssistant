package party.xiaoyu.glasses.wakeprobe;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.os.Build;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Locale;

/** Development-only LAN updater. The APK must match the installed signer. */
final class LanUpdater {
    private static final int MAX_APK = 32 * 1024 * 1024;
    private final Context context;
    static final class Prepared {
        final File file; final long code; final String version; final String sha256; final long size;
        Prepared(File file, long code, String version, String sha256, long size) {
            this.file = file; this.code = code; this.version = version; this.sha256 = sha256; this.size = size;
        }
    }
    LanUpdater(Context context) { this.context = context.getApplicationContext(); }

    private static byte[] get(String path, int limit) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(CompanionEndpoints.UPDATER_URL + path).openConnection();
        c.setConnectTimeout(5000); c.setReadTimeout(12000); c.setInstanceFollowRedirects(false);
        try {
            if (c.getResponseCode() != 200) throw new Exception("更新服务暂不可用");
            if (c.getContentLengthLong() > limit) throw new Exception("更新数据过大");
            try (InputStream in = c.getInputStream(); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[16384]; int count;
                while ((count = in.read(buffer)) != -1) {
                    if (out.size() + count > limit) throw new Exception("更新数据过大");
                    out.write(buffer, 0, count);
                }
                return out.toByteArray();
            }
        } finally { c.disconnect(); }
    }
    private long installedCode(PackageInfo info) { return Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode; }
    @SuppressWarnings("deprecation") Prepared checkAndDownload() throws Exception {
        if (CompanionEndpoints.UPDATER_URL.isEmpty()) throw new Exception("未配置局域网更新地址");
        ConnectivityManager network = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkInfo active = network == null ? null : network.getActiveNetworkInfo();
        if (active == null || !active.isConnected() || active.getType() != ConnectivityManager.TYPE_WIFI) throw new Exception("请先连接家庭 Wi-Fi");
        JSONObject manifest = new JSONObject(new String(get("/manifest.json", 4096), java.nio.charset.StandardCharsets.UTF_8));
        if (!"xiaomi-classmate-dev".equals(manifest.optString("format")) || !context.getPackageName().equals(manifest.optString("package"))) throw new Exception("更新信息不匹配");
        long code = manifest.optLong("versionCode", -1), size = manifest.optLong("size", -1);
        String version = manifest.optString("version", ""), expected = manifest.optString("sha256", "");
        if (code <= 0 || size <= 0 || size > MAX_APK || !version.matches("[0-9]+(\\.[0-9]+){1,3}") || !expected.matches("[0-9a-f]{64}")) throw new Exception("更新信息无效");
        PackageInfo installed = context.getPackageManager().getPackageInfo(context.getPackageName(), PackageManager.GET_SIGNATURES);
        if (code <= installedCode(installed)) return null;
        byte[] bytes = get("/app.apk", MAX_APK);
        if (bytes.length != size || !hex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(expected)) throw new Exception("下载内容校验失败");
        File apk = File.createTempFile("glasses-update-", ".apk", context.getCacheDir());
        boolean valid = false;
        try {
            try (FileOutputStream out = new FileOutputStream(apk)) { out.write(bytes); out.getFD().sync(); }
            PackageInfo incoming = context.getPackageManager().getPackageArchiveInfo(apk.getAbsolutePath(), PackageManager.GET_SIGNATURES);
            if (incoming == null || !context.getPackageName().equals(incoming.packageName) || installedCode(incoming) != code
                    || !version.equals(incoming.versionName) || installed.signatures == null || incoming.signatures == null
                    || installed.signatures.length != 1 || incoming.signatures.length != 1
                    || !Arrays.equals(installed.signatures[0].toByteArray(), incoming.signatures[0].toByteArray())) throw new Exception("更新包签名或版本不匹配");
            valid = true; return new Prepared(apk, code, version, expected, size);
        } finally { if (!valid) apk.delete(); }
    }
    static String hex(byte[] bytes) { StringBuilder out = new StringBuilder(); for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255)); return out.toString(); }
    @SuppressWarnings("deprecation") void install(Prepared update) throws Exception {
        if (!update.file.isFile() || update.file.length() != update.size) throw new Exception("更新包已失效，请重新检查");
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(update.file)) { byte[] b = new byte[16384]; int n; while ((n = in.read(b)) != -1) digest.update(b, 0, n); }
        if (!hex(digest.digest()).equals(update.sha256)) throw new Exception("更新包已改变，请重新检查");
        PackageManager pm = context.getPackageManager();
        PackageInfo current = pm.getPackageInfo(context.getPackageName(), PackageManager.GET_SIGNATURES);
        PackageInfo incoming = pm.getPackageArchiveInfo(update.file.getAbsolutePath(), PackageManager.GET_SIGNATURES);
        if (incoming == null || !context.getPackageName().equals(incoming.packageName) || installedCode(incoming) != update.code
                || update.code <= installedCode(current) || current.signatures == null || incoming.signatures == null
                || current.signatures.length != 1 || incoming.signatures.length != 1
                || !Arrays.equals(current.signatures[0].toByteArray(), incoming.signatures[0].toByteArray())) throw new Exception("更新包身份已失效");
        PackageInstaller installer = pm.getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(context.getPackageName()); params.setSize(update.size);
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED);
        int id = installer.createSession(params); boolean committed = false;
        try (PackageInstaller.Session session = installer.openSession(id)) {
            try (InputStream in = new FileInputStream(update.file); OutputStream out = session.openWrite("base.apk", 0, update.size)) {
                byte[] b = new byte[16384]; int n; while ((n = in.read(b)) != -1) out.write(b, 0, n); session.fsync(out);
            }
            Intent callback = new Intent(context, UpdateInstallReceiver.class).setAction(context.getPackageName() + ".UPDATE_INSTALL");
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
            session.commit(PendingIntent.getBroadcast(context, id, callback, flags).getIntentSender()); committed = true;
        } finally { if (!committed) installer.abandonSession(id); }
    }
}
