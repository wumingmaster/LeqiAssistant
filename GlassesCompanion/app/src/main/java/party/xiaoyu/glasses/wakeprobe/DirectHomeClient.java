package party.xiaoyu.glasses.wakeprobe;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONObject;

/** HTTPS-only client; callers supply a credential at runtime, never in the APK. */
final class DirectHomeClient {
    enum ForwardOutcome { FORWARDED, REJECTED, UNKNOWN }

    JSONObject fetchStatus(String token) throws Exception {
        HttpsURLConnection connection = open("/v1/status", token);
        try {
            int code = connection.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code);
            return readObject(connection.getInputStream());
        } finally { connection.disconnect(); }
    }

    static JSONObject dashboard(JSONObject response) throws Exception {
        JSONObject devices = response.getJSONObject("devices");
        JSONObject result = new JSONObject();
        for (String name : new String[]{"temperature", "humidity", "tvoc", "living_temperature", "living_humidity",
                "washer_status", "washer_remaining", "footbath_power", "footbath_temperature",
                "cooker_status", "cooker_stage", "cooker_pressure_stage", "cooker_remaining"}) {
            JSONObject entity = devices.optJSONObject(name);
            result.put(name, entity == null ? JSONObject.NULL : entity.opt("state"));
        }
        JSONObject tvoc = devices.optJSONObject("tvoc");
        JSONObject heater = devices.optJSONObject("heater");
        if (heater != null) {
            result.put("heater_state", heater.opt("state"));
            result.put("heater_current", heater.opt("current_temperature"));
            result.put("heater_target", heater.opt("temperature"));
            result.put("heater_mode", heater.opt("preset_mode"));
        }
        if (tvoc != null && !tvoc.isNull("state")) {
            String unit = tvoc.optString("unit", "");
            double number = tvoc.optDouble("state", Double.NaN);
            if (!Double.isNaN(number)) {
                boolean micro = unit.equals("μg/m³") || unit.equals("µg/m³") || unit.equals("ug/m³");
                result.put("tvoc", String.format(Locale.ROOT, "%.2f %s", micro ? number / 1000 : number, micro ? "mg/m³" : unit));
            }
        }
        JSONObject washer = devices.optJSONObject("washer_waiting");
        if (washer != null) {
            result.put("washer_waiting", washer.opt("state"));
            result.put("washer_waiting_minutes", washer.opt("minutes"));
        }
        result.put("updated_at", new SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(new Date()));
        return result;
    }

    ForwardOutcome forwardXiaoai(String token, String text) {
        if (text == null || text.trim().isEmpty() || text.length() > 500) return ForwardOutcome.REJECTED;
        HttpsURLConnection connection = null;
        try {
            connection = open("/v1/xiaoai", token);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
            byte[] data = new JSONObject().put("text", text.trim()).toString().getBytes(StandardCharsets.UTF_8);
            try (OutputStream stream = connection.getOutputStream()) { stream.write(data); }
            int code = connection.getResponseCode();
            InputStream stream = code < 400 ? connection.getInputStream() : connection.getErrorStream();
            JSONObject result = stream == null ? new JSONObject() : readObject(stream);
            String outcome = result.optString("outcome");
            if (code == 200 && "forwarded".equals(outcome)) return ForwardOutcome.FORWARDED;
            if ("rejected".equals(outcome) || code == 401 || code == 403 || code == 400) return ForwardOutcome.REJECTED;
        } catch (Exception ignored) {
            // A timeout can occur after execution; never automatically repeat a command.
        } finally { if (connection != null) connection.disconnect(); }
        return ForwardOutcome.UNKNOWN;
    }

    String transcribe(String token, byte[] pcm) throws Exception {
        if (pcm == null || pcm.length < 16000 || pcm.length > 256000 || pcm.length % 2 != 0)
            throw new IOException("invalid audio");
        HttpsURLConnection connection = open("/v1/transcribe", token);
        try {
            connection.setReadTimeout(45000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/octet-stream");
            connection.setFixedLengthStreamingMode(pcm.length);
            try (OutputStream stream = connection.getOutputStream()) { stream.write(pcm); }
            int code = connection.getResponseCode();
            if (code != 200) throw new IOException("recognition unavailable: HTTP " + code);
            return readObject(connection.getInputStream()).optString("text", "").trim();
        } finally { connection.disconnect(); }
    }

    private HttpsURLConnection open(String path, String token) throws IOException {
        if (token == null || token.isEmpty()) throw new IOException("credential unavailable");
        if (CompanionEndpoints.HOME_URL.isEmpty()) throw new IOException("home service not configured");
        HttpsURLConnection connection = (HttpsURLConnection) new URL(CompanionEndpoints.HOME_URL + path).openConnection();
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(6000);
        connection.setReadTimeout(8000);
        connection.setUseCaches(false);
        connection.setRequestProperty("Authorization", "Bearer " + token);
        return connection;
    }

    private JSONObject readObject(InputStream input) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try (InputStream stream = input) {
            byte[] buffer = new byte[2048]; int count;
            while ((count = stream.read(buffer)) != -1) {
                if (output.size() + count > 131072) throw new IOException("response too large");
                output.write(buffer, 0, count);
            }
        }
        return new JSONObject(new String(output.toByteArray(), StandardCharsets.UTF_8));
    }
}
