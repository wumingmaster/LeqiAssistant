package party.xiaoyu.glasses.wakeprobe;

import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONTokener;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Local display mirror of received Rokid schedule messages; never writes to Rokid. */
final class ScheduleMirror {
    private static final int LIMIT = 500;
    private final Map<String, JSONObject> events = new LinkedHashMap<>();

    ScheduleMirror(String saved) {
        try {
            JSONArray array = new JSONArray(saved == null ? "[]" : saved);
            if (array.length() <= LIMIT) for (int i = 0; i < array.length(); i++) {
                JSONObject normalized = normalize(array.optJSONObject(i));
                if (normalized != null) events.put(normalized.optString("id"), normalized);
            }
        } catch (Exception ignored) { }
    }

    boolean accept(String command, String payload) {
        if (payload == null || payload.length() > 65536) return false;
        try {
            Object root = new JSONTokener(payload).nextValue();
            if ("Schedule_Add".equals(command)) {
                JSONObject event = normalize(root instanceof JSONObject ? (JSONObject) root : null);
                if (event == null || (events.size() >= LIMIT && !events.containsKey(event.optString("id")))) return false;
                events.put(event.optString("id"), event);
                return true;
            }
            if ("Schedule_Remove".equals(command)) {
                String id = root instanceof JSONObject ? ((JSONObject) root).optString("id", "") : String.valueOf(root);
                if (id.isEmpty() || id.length() > 128) return false;
                events.remove(id);
                return true;
            }
            if ("Schedule_Sync".equals(command) && root instanceof JSONArray) {
                JSONArray array = (JSONArray) root;
                if (array.length() > LIMIT) return false;
                Map<String, JSONObject> replacement = new LinkedHashMap<>();
                for (int i = 0; i < array.length(); i++) {
                    JSONObject event = normalize(array.optJSONObject(i));
                    if (event == null || replacement.put(event.optString("id"), event) != null) return false;
                }
                events.clear(); events.putAll(replacement);
                return true;
            }
        } catch (Exception ignored) { }
        return false;
    }

    String serialize() {
        JSONArray result = new JSONArray();
        for (JSONObject event : events.values()) result.put(event);
        return result.toString();
    }

    String diagnostic(String payload, boolean accepted, long nowMillis) {
        try {
            Object root = new JSONTokener(payload).nextValue();
            if (!(root instanceof JSONObject)) return accepted ? "已接收" : "数据不是单条对象";
            JSONObject item = (JSONObject) root;
            Object raw = item.opt("scheduleTime");
            String timeType = raw == null || raw == JSONObject.NULL ? "空" : raw.getClass().getSimpleName();
            JSONObject normalized = normalize(item);
            if (normalized == null) return "未解析：时间 " + timeType + " " + item.optString("scheduleTime", "").length()
                    + "位，ID/标题/内容非空 " + (!item.optString("id", "").isEmpty()) + "/"
                    + (!item.optString("title", "").isEmpty()) + "/" + (!item.optString("description", "").isEmpty());
            long when = normalized.optLong("scheduleTime");
            return accepted ? (when >= nowMillis ? "已缓存，时间未过" : "已缓存，时间已过") : "解析成功但未写入";
        } catch (Exception ignored) { return "无法解析消息"; }
    }

    String display(long nowMillis, ZoneId zone) {
        List<JSONObject> upcoming = new ArrayList<>();
        for (JSONObject event : events.values()) if (event.optLong("scheduleTime", 0) >= nowMillis) upcoming.add(event);
        upcoming.sort(Comparator.comparingLong(e -> e.optLong("scheduleTime", 0)));
        if (upcoming.isEmpty()) return "";
        StringBuilder out = new StringBuilder("\n日程");
        LocalDate today = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate();
        DateTimeFormatter clock = DateTimeFormatter.ofPattern("HH:mm");
        DateTimeFormatter date = DateTimeFormatter.ofPattern("MM-dd HH:mm");
        for (int i = 0; i < Math.min(2, upcoming.size()); i++) {
            JSONObject event = upcoming.get(i);
            java.time.ZonedDateTime at = Instant.ofEpochMilli(event.optLong("scheduleTime")).atZone(zone);
            out.append('\n').append(at.format(at.toLocalDate().equals(today) ? clock : date)).append(' ').append(event.optString("title"));
        }
        return out.toString();
    }

    private static JSONObject normalize(JSONObject source) {
        if (source == null || source.isNull("id") || source.isNull("scheduleTime")) return null;
        try {
            String id = source.optString("id", "").trim();
            String title = source.optString("title", "").replaceAll("[\\p{Cntrl}\\r\\n]+", " ").trim();
            if (title.isEmpty() || "null".equals(title)) title = source.isNull("description") ? "" : source.optString("description", "").replaceAll("[\\p{Cntrl}\\r\\n]+", " ").trim();
            long at = Long.parseLong(source.optString("scheduleTime", ""));
            if (at > 1_000_000_000L && at < 10_000_000_000L) at *= 1000;
            if (id.isEmpty() || id.length() > 128 || title.isEmpty() || at < 946684800000L || at > 4102444800000L) return null;
            if (title.length() > 80) title = title.substring(0, 80);
            JSONObject event = new JSONObject();
            event.put("id", id); event.put("title", title); event.put("scheduleTime", at);
            return event;
        } catch (Exception ignored) { return null; }
    }
}
