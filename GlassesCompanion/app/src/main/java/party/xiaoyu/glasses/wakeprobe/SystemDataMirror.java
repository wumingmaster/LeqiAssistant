package party.xiaoyu.glasses.wakeprobe;

import android.os.SystemClock;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;

/** Snapshot of data received from the Rokid sync channels. */
final class SystemDataMirror {
    static final String REQUEST = "LEQI_SYSTEM_READ:";
    private static final int LEGACY_CHUNK_BYTES = 600;
    private static final int SMALL_CHUNK_BYTES = 240;
    private static final java.util.regex.Pattern READ_REQUEST = java.util.regex.Pattern.compile(
            "LEQI_SYSTEM_READ:([0-9a-f]{32}):([0-9]{1,6})(?::(240))?(?![a-zA-Z0-9_:])");
    private static final int MAX_MEMO_COUNT = 500;

    private JSONArray memos;
    private String transferId;
    private byte[] transfer;
    private long transferUntil;

    String savedMemos() { return memos == null ? null : memos.toString(); }

    boolean acceptMemos(String command, String payload) {
        if (!"Memo_Sync".equals(command) || payload == null || payload.length() > 65536) return false;
        try {
            Object root = new JSONTokener(payload).nextValue();
            if (!(root instanceof JSONArray)) return false;
            JSONArray records = (JSONArray) root;
            if (records.length() > MAX_MEMO_COUNT) return false;
            JSONArray replacement = new JSONArray();
            java.util.HashSet<String> ids = new java.util.HashSet<>();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                String id = record.optString("id", "").trim();
                String title = string(record, "title");
                String content = string(record, "content");
                if (content.isEmpty()) content = string(record, "description");
                if (id.isEmpty() || id.length() > 128 || !ids.add(id)
                        || (title.isEmpty() && content.isEmpty())) return false;
                JSONObject memo = new JSONObject();
                memo.put("id", id);
                memo.put("title", title);
                memo.put("content", content);
                replacement.put(memo);
            }
            memos = replacement;
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    private static String string(JSONObject record, String key) {
        Object value = record.opt(key);
        return value instanceof String ? (String) value : "";
    }

    String memoPreview() {
        if (memos == null || memos.length() == 0) return "";
        JSONObject memo = memos.optJSONObject(0);
        String title = memo.optString("title").trim();
        String text = title.isEmpty() ? memo.optString("content").trim() : title;
        return text.isEmpty() ? "" : "便签\n" + text;
    }

    String reply(String request, ScheduleMirror schedule, boolean scheduleReceived) {
        java.util.regex.Matcher fields = READ_REQUEST.matcher(request);
        if (!fields.lookingAt()) return null;
        String id = fields.group(1);
        int offset = Integer.parseInt(fields.group(2));
        int chunkBytes = fields.group(3) == null ? LEGACY_CHUNK_BYTES : SMALL_CHUNK_BYTES;
        long now = SystemClock.elapsedRealtime();
        if (offset == 0 && (!id.equals(transferId) || now > transferUntil)) {
            try {
                JSONObject snapshot = new JSONObject();
                if (scheduleReceived) snapshot.put("events", new JSONArray(schedule.serialize()));
                if (memos != null) snapshot.put("memos", memos);
                transfer = snapshot.toString().getBytes(StandardCharsets.UTF_8);
                transferId = id;
            } catch (Exception ignored) {
                return "LEQI_SYSTEM_ERROR:" + id;
            }
        }
        if (!id.equals(transferId) || transfer == null || offset >= transfer.length
                || (offset > 0 && now > transferUntil)) return "LEQI_SYSTEM_ERROR:" + id;
        transferUntil = now + 15000;
        int end = Math.min(transfer.length, offset + chunkBytes);
        String data = Base64.encodeToString(Arrays.copyOfRange(transfer, offset, end), Base64.NO_WRAP);
        return "LEQI_SYSTEM_DATA:" + id + ":" + offset + ":" + transfer.length + ":" + data;
    }

    void clear() {
        memos = null;
        transferId = null;
        transfer = null;
        transferUntil = 0;
    }
}
