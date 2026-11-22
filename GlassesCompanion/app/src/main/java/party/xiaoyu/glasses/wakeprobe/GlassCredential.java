package party.xiaoyu.glasses.wakeprobe;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Stores a separately provisioned bridge credential using a device-local key. */
final class GlassCredential {
    private static final String ALIAS = "xiaomi-classmate-bridge-v1";
    private static final String PREF = "direct-bridge";
    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (!store.containsAlias(ALIAS)) {
            KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            gen.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            gen.generateKey();
        }
        return (SecretKey) store.getKey(ALIAS, null);
    }
    static void save(Context context, String token) throws Exception {
        if (token == null || !token.matches("[a-f0-9]{64}")) throw new IllegalArgumentException("invalid credential");
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, key());
        String iv = Base64.encodeToString(c.getIV(), Base64.NO_WRAP);
        String encrypted = Base64.encodeToString(c.doFinal(token.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
        if (!context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString("iv", iv).putString("ciphertext", encrypted).commit())
            throw new IllegalStateException("credential not saved");
    }
    static String load(Context context) throws Exception {
        android.content.SharedPreferences p = context.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        String iv = p.getString("iv", null), encrypted = p.getString("ciphertext", null);
        if (iv == null || encrypted == null) return null;
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)));
        return new String(c.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), StandardCharsets.UTF_8);
    }
}
