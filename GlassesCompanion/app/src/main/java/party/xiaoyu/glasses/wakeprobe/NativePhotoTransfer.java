package party.xiaoyu.glasses.wakeprobe;

import android.Manifest;
import android.app.Activity;
import android.content.ContentUris;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.SystemClock;
import android.provider.MediaStore;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Only a newly created, unambiguous camera image from an armed request may be read. */
final class NativePhotoTransfer {
    interface Reply { void send(String message); }
    private static final Uri IMAGES = MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
    private final Activity activity;
    private final Reply reply;
    private String activeId;
    private long baseline, expires;
    private boolean fetching;
    NativePhotoTransfer(Activity activity, Reply reply) { this.activity = activity; this.reply = reply; }

    void arm(String message) {
        String[] p = message.split(":", -1);
        if (p.length != 5 || !p[1].matches("[a-f0-9]{32}") || !privateAddress(p[2])
                || !p[3].matches("[0-9]{1,5}") || !p[4].matches("[a-f0-9]{32}")) return;
        String id = p[1]; int port = Integer.parseInt(p[3]);
        if (port < 1 || port > 65535) return;
        if (activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.i("NativePhotoTransfer", "permission required");
            activity.requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE}, 144);
            reply.send("NATIVE_PHOTO_ERROR:" + id + ":permission");
            return;
        }
        try {
            baseline = newestCameraId(); activeId = id; fetching = false;
            android.util.Log.i("NativePhotoTransfer", "armed");
            expires = SystemClock.elapsedRealtime() + 60000;
            new Thread(() -> {
                try (Socket socket = new Socket()) {
                    socket.connect(new InetSocketAddress(p[2], port), 5000);
                    OutputStream out = socket.getOutputStream();
                    out.write((p[4] + "\nREADY").getBytes(StandardCharsets.US_ASCII)); out.flush();
                    reply.send("NATIVE_PHOTO_ARMED:" + id);
                } catch (Exception e) {
                    activity.runOnUiThread(() -> { if (id.equals(activeId)) activeId = null; });
                    reply.send("NATIVE_PHOTO_ERROR:" + id + ":network");
                }
            }, "native-photo-preflight").start();
        } catch (Exception e) { reply.send("NATIVE_PHOTO_ERROR:" + id + ":arm"); }
    }

    void fetch(String message) {
        String[] p = message.split(":", -1);
        if (p.length != 6 || !p[1].matches("[a-f0-9]{32}") || !p[1].equals(activeId) || fetching
                || SystemClock.elapsedRealtime() >= expires || !privateAddress(p[2])
                || !p[3].matches("[0-9]{1,5}") || !p[4].matches("[a-f0-9]{32}")
                || !p[5].matches("[A-Za-z0-9_-]{43}")) return;
        int port = Integer.parseInt(p[3]);
        if (port < 1 || port > 65535) return;
        byte[] key;
        try { key = Base64.decode(p[5], Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING); }
        catch (Exception e) { return; }
        if (key.length != 32) return;
        fetching = true;
        final String requestId = p[1], host = p[2], token = p[4];
        final long minimumId = baseline, deadline = expires;
        new Thread(() -> {
            try {
                long selected = awaitNewPhoto(minimumId, deadline);
                android.util.Log.i("NativePhotoTransfer", "new camera photo located");
                byte[] image = readImage(selected);
                byte[] nonce = new byte[12]; new SecureRandom().nextBytes(nonce);
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
                cipher.updateAAD(requestId.getBytes(StandardCharsets.US_ASCII));
                byte[] encrypted = cipher.doFinal(image);
                try (Socket socket = new Socket()) {
                    socket.connect(new InetSocketAddress(host, port), 5000);
                    OutputStream out = socket.getOutputStream();
                    out.write((token + "\n").getBytes(StandardCharsets.US_ASCII)); out.write(nonce); out.write(encrypted); out.flush();
                }
                reply.send("NATIVE_PHOTO_SENT:" + requestId);
            } catch (Exception e) {
                android.util.Log.i("NativePhotoTransfer", "transfer failed: " + e.getClass().getSimpleName());
                reply.send("NATIVE_PHOTO_ERROR:" + requestId + ":transfer");
            }
            finally { java.util.Arrays.fill(key, (byte) 0); activity.runOnUiThread(() -> { if (requestId.equals(activeId)) activeId = null; }); }
        }, "native-photo-transfer").start();
    }

    private long newestCameraId() {
        try (Cursor c = activity.getContentResolver().query(IMAGES, new String[]{MediaStore.Images.Media._ID},
                MediaStore.Images.Media.RELATIVE_PATH + "=?", new String[]{"DCIM/Camera/"}, MediaStore.Images.Media._ID + " DESC")) {
            if (c == null) throw new IllegalStateException();
            return c.moveToFirst() ? c.getLong(0) : 0;
        }
    }
    private long awaitNewPhoto(long minimum, long deadline) throws Exception {
        long prior = -1, priorSize = -1; int stable = 0;
        while (SystemClock.elapsedRealtime() < deadline) {
            long found = -1, size = 0; int count = 0;
            try (Cursor c = activity.getContentResolver().query(IMAGES,
                    new String[]{MediaStore.Images.Media._ID, MediaStore.Images.Media.SIZE},
                    MediaStore.Images.Media.RELATIVE_PATH + "=? AND " + MediaStore.Images.Media._ID + ">?",
                    new String[]{"DCIM/Camera/", Long.toString(minimum)}, MediaStore.Images.Media._ID + " ASC")) {
                if (c == null) throw new IllegalStateException();
                while (c.moveToNext()) { count++; found = c.getLong(0); size = c.getLong(1); if (count > 1) break; }
            }
            if (count > 1) throw new IllegalStateException("ambiguous");
            if (count == 1 && size > 0 && found == prior && size == priorSize) stable++; else stable = 0;
            if (stable >= 3) return found;
            prior = found; priorSize = size; Thread.sleep(500);
        }
        throw new IllegalStateException("timeout");
    }
    private byte[] readImage(long id) throws Exception {
        try (InputStream in = activity.getContentResolver().openInputStream(ContentUris.withAppendedId(IMAGES, id));
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            if (in == null) throw new IllegalStateException();
            byte[] buffer = new byte[8192]; int n;
            while ((n = in.read(buffer)) != -1) { if (out.size() + n > 16 * 1024 * 1024) throw new IllegalStateException(); out.write(buffer, 0, n); }
            if (out.size() == 0) throw new IllegalStateException();
            return out.toByteArray();
        }
    }
    private static boolean privateAddress(String value) {
        return value.matches("(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)[0-9.]+") && value.length() <= 15;
    }
}
