package party.xiaoyu.glasses.wakeprobe;

import android.util.Base64;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;
import java.util.Locale;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Ephemeral ECDH pairing, confirmed by comparing a six-digit code on both devices. */
final class PairingSession {
    final String id;
    final String publicKey;
    final String code;
    private final byte[] key;
    private final long expires;
    PairingSession(String id, String peerBase64) throws Exception {
        if (!id.matches("[a-f0-9-]{36}")) throw new IllegalArgumentException("invalid id");
        byte[] peer = Base64.decode(peerBase64, Base64.NO_WRAP);
        if (peer.length != 65 || peer[0] != 4) throw new IllegalArgumentException("invalid key");
        AlgorithmParameters ap = AlgorithmParameters.getInstance("EC");
        ap.init(new ECGenParameterSpec("secp256r1"));
        ECParameterSpec spec = ap.getParameterSpec(ECParameterSpec.class);
        ECPoint point = new ECPoint(new BigInteger(1, Arrays.copyOfRange(peer, 1, 33)), new BigInteger(1, Arrays.copyOfRange(peer, 33, 65)));
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        KeyPair own = generator.generateKeyPair();
        KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
        agreement.init(own.getPrivate());
        agreement.doPhase(KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(point, spec)), true);
        byte[] secret = agreement.generateSecret();
        byte[] salt = id.getBytes(StandardCharsets.UTF_8);
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(secret);
        mac.init(new SecretKeySpec(prk, "HmacSHA256"));
        byte[] info = "xiaomi-classmate-pair-v1\u0001".getBytes(StandardCharsets.UTF_8);
        key = mac.doFinal(info);
        Arrays.fill(secret, (byte) 0);
        Arrays.fill(prk, (byte) 0);
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        byte[] verifier = mac.doFinal("verify".getBytes(StandardCharsets.UTF_8));
        long n = ByteBuffer.wrap(verifier).getInt() & 0xffffffffL;
        code = String.format(Locale.ROOT, "%06d", n % 1000000);
        ECPublicKey publicPart = (ECPublicKey) own.getPublic();
        byte[] encoded = new byte[65]; encoded[0] = 4;
        coordinate(publicPart.getW().getAffineX(), encoded, 1);
        coordinate(publicPart.getW().getAffineY(), encoded, 33);
        publicKey = Base64.encodeToString(encoded, Base64.NO_WRAP);
        this.id = id;
        expires = System.currentTimeMillis() + 120000;
    }
    private static void coordinate(BigInteger value, byte[] output, int offset) {
        byte[] b = value.toByteArray(); int length = Math.min(32, b.length);
        System.arraycopy(b, b.length - length, output, offset + 32 - length, length);
    }
    String decrypt(String suppliedId, String nonce, String ciphertext) throws Exception {
        if (!id.equals(suppliedId) || System.currentTimeMillis() > expires) throw new IllegalStateException("expired");
        byte[] iv = Base64.decode(nonce, Base64.NO_WRAP);
        if (iv.length != 12) throw new IllegalArgumentException("invalid nonce");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        cipher.updateAAD(id.getBytes(StandardCharsets.UTF_8));
        return new String(cipher.doFinal(Base64.decode(ciphertext, Base64.NO_WRAP)), StandardCharsets.UTF_8);
    }
}
