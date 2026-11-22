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
import java.io.File;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Explicit requests only. Do not guess when two recent camera images overlap. */
final class NativePhotoParallelTransfer {
    interface Reply { void send(String value); }
    private static final Uri IMAGES = MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
    private final Activity activity;
    private final Reply reply;
    private boolean busy;
    private String activeId;
    private final java.util.LinkedHashMap<String, String> completedReplies = new java.util.LinkedHashMap<>();
    NativePhotoParallelTransfer(Activity activity, Reply reply) { this.activity = activity; this.reply = reply; }

    void start(String message) {
        String[] p = message.split(":", -1);
        boolean benchmark = p[0].equals("PHOTO_NATIVE_BENCH");
        boolean album = p[0].equals("PHOTO_ALBUM_NEXT");
        android.util.Log.i("ParallelPhoto", "request received mode=" + p[0] + " fields=" + p.length);
        if (p.length < 2 || !p[1].matches("[a-f0-9]{32}")) {
            android.util.Log.i("ParallelPhoto", "request rejected: id");
            return;
        }
        final String id=p[1];
        String completed = completedReplies.get(id);
        if (completed != null) { reply.send(completed); return; }
        if (busy && id.equals(activeId)) { reply.send("PARALLEL_PHOTO_ACCEPTED:"+id); return; }
        if (busy) return;
        if (p.length != (album || benchmark ? 8 : 7)) { reject(id, "fields"); return; }
        if (!privateAddress(p[2]) || !p[3].matches("[0-9]{1,5}")) { reject(id, "address"); return; }
        if (!p[4].matches("[a-f0-9]{32}") || !p[5].matches("[A-Za-z0-9_-]{43}")) { reject(id, "credentials"); return; }
        if (!p[6].matches("[0-9]{10,13}")) { reject(id, "timestamp"); return; }
        if (album && !p[7].matches("[0-9]{1,18}")) { reject(id, "cursor"); return; }
        final String host=p[2], token=p[4];
        int port = Integer.parseInt(p[3]); long at = Long.parseLong(p[6]);
        final long after = album ? Long.parseLong(p[7]) : 0;
        final int parts;
        try { parts = benchmark ? Integer.parseInt(p[7]) : 4; } catch (Exception e) { return; }
        if (parts != 1 && parts != 2 && parts != 4 && parts != 8) return;
        if (port < 1 || port > 65535) { reject(id, "address"); return; }
        if (at < System.currentTimeMillis()-30000 || at > System.currentTimeMillis()+3000) { reject(id, "clock"); return; }
        if (activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE}, 145);
            reply.send("PARALLEL_PHOTO_ERROR:"+id+":permission"); return;
        }
        final byte[] key;
        try { key=Base64.decode(p[5],Base64.URL_SAFE|Base64.NO_WRAP|Base64.NO_PADDING); }
        catch(Exception e){return;}
        if(key.length!=32)return;
        busy=true; activeId=id;
        android.util.Log.i("ParallelPhoto", "request accepted");
        reply.send("PARALLEL_PHOTO_ACCEPTED:"+id);
        new Thread(() -> {
            ExecutorService pool=Executors.newFixedThreadPool(parts);
            try {
                byte[] image;
                if (benchmark) { image = new byte[3*1024*1024]; Arrays.fill(image, (byte) 65); }
                else if (album) {
                    long photoId = nextAlbumPhoto(after, at);
                    if (photoId < 0) {
                        finish(id, "PARALLEL_PHOTO_EMPTY:" + id);
                        android.util.Log.i("ParallelPhoto", "album has no more photos");
                        return;
                    }
                    byte[] photo = readImage(photoId);
                    image = ByteBuffer.allocate(Long.BYTES + photo.length).putLong(photoId).put(photo).array();
                } else { long photoId=awaitRecentPhoto(at); android.util.Log.i("ParallelPhoto", "new photo located"); image=readImage(photoId); }
                if(image.length<4)throw new IllegalStateException("small");
                int total=image.length; int chunkSize=(total+parts-1)/parts;
                @SuppressWarnings("unchecked") Future<?>[] tasks=new Future<?>[parts];
                for(int i=0;i<parts;i++){
                    final int part=i, from=i*chunkSize, to=Math.min(total,(i+1)*chunkSize);
                    tasks[i]=pool.submit(() -> {
                        try {
                            byte[] nonce=new byte[12];new SecureRandom().nextBytes(nonce);
                            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
                            cipher.init(Cipher.ENCRYPT_MODE,new SecretKeySpec(key,"AES"),new GCMParameterSpec(128,nonce));
                            cipher.updateAAD((id+":"+part+":"+total).getBytes(StandardCharsets.US_ASCII));
                            byte[] encrypted=cipher.doFinal(image,from,to-from);
                            try(Socket socket=new Socket()){
                                socket.connect(new InetSocketAddress(host,port),5000);
                                OutputStream out=socket.getOutputStream();
                                out.write((token+":"+part+":"+total+"\n").getBytes(StandardCharsets.US_ASCII));
                                out.write(nonce);out.write(encrypted);out.flush();
                            }
                        } catch(Exception e){throw new RuntimeException(e);}
                    });
                }
                for(Future<?> task:tasks)task.get();
                finish(id, "PARALLEL_PHOTO_SENT:"+id);
                android.util.Log.i("ParallelPhoto", "encrypted fragments sent count="+parts);
            } catch(Exception e) {
                android.util.Log.i("ParallelPhoto", "transfer failed: "+e.getClass().getSimpleName());
                finish(id, "PARALLEL_PHOTO_ERROR:"+id+":transfer");
            } finally {
                pool.shutdownNow();
                Arrays.fill(key, (byte) 0);
            }
        },"parallel-native-photo").start();
    }
    private void finish(String id, String response) {
        activity.runOnUiThread(() -> {
            completedReplies.put(id, response);
            if (completedReplies.size() > 32) completedReplies.remove(completedReplies.keySet().iterator().next());
            busy = false;
            activeId = null;
            reply.send(response);
        });
    }
    private void reject(String id, String reason) {
        android.util.Log.i("ParallelPhoto", "request rejected: " + reason);
        reply.send("PARALLEL_PHOTO_ERROR:" + id + ":" + reason);
    }
    private long nextAlbumPhoto(long after, long requestedAt) {
        String filter = MediaStore.Images.Media.RELATIVE_PATH + "=? AND "
                + MediaStore.Images.Media._ID + ">? AND " + MediaStore.Images.Media.SIZE + ">0 AND "
                + MediaStore.Images.Media.IS_PENDING + "=0";
        if (after == 0) filter += " AND " + MediaStore.Images.Media.DATE_ADDED + ">=?";
        String[] args = after == 0
                ? new String[]{"DCIM/Camera/", "0", Long.toString(requestedAt / 1000 - 86400)}
                : new String[]{"DCIM/Camera/", Long.toString(after)};
        try (Cursor cursor = activity.getContentResolver().query(IMAGES,
                new String[]{MediaStore.Images.Media._ID}, filter, args,
                MediaStore.Images.Media._ID + " ASC")) {
            if (cursor == null) throw new IllegalStateException("query");
            return cursor.moveToFirst() ? cursor.getLong(0) : -1;
        }
    }

    private long awaitRecentPhoto(long at) throws Exception {
        long deadline=SystemClock.elapsedRealtime()+20000, previous=-1, priorSize=-1;int stable=0;
        while(SystemClock.elapsedRealtime()<deadline){
            int count=0;long id=-1,size=0;
            try(Cursor c=activity.getContentResolver().query(IMAGES,
                    new String[]{MediaStore.Images.Media._ID,MediaStore.Images.Media.SIZE,MediaStore.Images.Media.DATA},
                    MediaStore.Images.Media.RELATIVE_PATH+"=? AND "+MediaStore.Images.Media.DATE_ADDED+">=? AND "+MediaStore.Images.Media.DATE_ADDED+"<=?",
                    new String[]{"DCIM/Camera/",Long.toString(at/1000-1),Long.toString(at/1000+20)},MediaStore.Images.Media._ID+" ASC")){
                if(c==null)throw new IllegalStateException("query");
                while(c.moveToNext()){
                    String path=c.getString(2);
                    // MediaStore DATE_ADDED has only second precision. Refuse
                    // to select a photo whose file was last modified before
                    // this request, even if it falls in the same second.
                    if(path==null || new File(path).lastModified()<at)continue;
                    count++;id=c.getLong(0);size=c.getLong(1);if(count>1)break;
                }
            }
            if(count>1)throw new IllegalStateException("ambiguous");
            if(count==1 && size>0 && id==previous && size==priorSize)stable++;else stable=0;
            if(stable>=2)return id;
            previous=id;priorSize=size;Thread.sleep(500);
        }
        throw new IllegalStateException("timeout");
    }
    private byte[] readImage(long id)throws Exception{
        try(InputStream in=activity.getContentResolver().openInputStream(ContentUris.withAppendedId(IMAGES,id));ByteArrayOutputStream out=new ByteArrayOutputStream()){
            if(in==null)throw new IllegalStateException("read");byte[] b=new byte[8192];int n;
            while((n=in.read(b))!=-1){if(out.size()+n>16*1024*1024)throw new IllegalStateException("size");out.write(b,0,n);}return out.toByteArray();
        }
    }
    private static boolean privateAddress(String v){return v.matches("(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)[0-9.]+")&&v.length()<=15;}
}
