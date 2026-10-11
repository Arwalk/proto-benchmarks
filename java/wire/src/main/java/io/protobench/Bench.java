package io.protobench;

import com.squareup.moshi.JsonAdapter;
import com.squareup.moshi.Moshi;
import com.squareup.wire.WireJsonAdapterFactory;
import io.protobench.bench.LargeMessage;
import io.protobench.bench.MediumMessage;
import io.protobench.bench.SmallMessage;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;

/** proto-benchmarks harness: Square Wire (Java codegen) + wire-moshi-adapter for JSON. */
public final class Bench extends Harness {
    // Moshi and its adapters are immutable and thread-safe; created once and reused as documented.
    static final Moshi MOSHI = new Moshi.Builder().add(new WireJsonAdapterFactory()).build();
    static final JsonAdapter<SmallMessage> SMALL_JSON = MOSHI.adapter(SmallMessage.class);
    static final JsonAdapter<MediumMessage> MEDIUM_JSON = MOSHI.adapter(MediumMessage.class);
    static final JsonAdapter<LargeMessage> LARGE_JSON = MOSHI.adapter(LargeMessage.class);

    @Override protected String language() { return "java"; }
    @Override protected String name() { return "wire"; }

    @Override protected String runtime() {
        StringBuilder gcs = new StringBuilder();
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            if (gcs.length() > 0) gcs.append('/');
            gcs.append(gc.getName());
        }
        return System.getProperty("java.vm.name") + " " + System.getProperty("java.runtime.version")
                + " (" + gcs + ", " + Runtime.getRuntime().availableProcessors() + " cpus)";
    }

    @Override protected String libraryVersion() {
        // Wire has no runtime version API; run.sh passes the version build.sh resolved into build/version.txt.
        return System.getProperty("protobench.library.version", "?");
    }

    @Override protected Dataset<?> dataset(String name) {
        return switch (name) {
            case "small" -> new Small();
            case "medium" -> new Medium();
            case "large" -> new Large();
            default -> throw new IllegalArgumentException(name);
        };
    }

    // One final class per dataset so every timed loop is monomorphic (static generated code only).

    static final class Small extends Dataset<SmallMessage> {
        @Override public SmallMessage wireDecode(byte[] data) throws Exception { return SmallMessage.ADAPTER.decode(data); }
        @Override public byte[] wireEncode(SmallMessage msg) { return SmallMessage.ADAPTER.encode(msg); }
        @Override public SmallMessage jsonDecode(String text) throws Exception { return SMALL_JSON.fromJson(text); }
        @Override public String jsonEncode(SmallMessage msg) { return SMALL_JSON.toJson(msg); }
        @Override public long scalar(SmallMessage msg) { return msg.id; }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(SmallMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(SmallMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    static final class Medium extends Dataset<MediumMessage> {
        @Override public MediumMessage wireDecode(byte[] data) throws Exception { return MediumMessage.ADAPTER.decode(data); }
        @Override public byte[] wireEncode(MediumMessage msg) { return MediumMessage.ADAPTER.encode(msg); }
        @Override public MediumMessage jsonDecode(String text) throws Exception { return MEDIUM_JSON.fromJson(text); }
        @Override public String jsonEncode(MediumMessage msg) { return MEDIUM_JSON.toJson(msg); }
        @Override public long scalar(MediumMessage msg) { return msg.created_at; }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(MediumMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(MediumMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    static final class Large extends Dataset<LargeMessage> {
        @Override public LargeMessage wireDecode(byte[] data) throws Exception { return LargeMessage.ADAPTER.decode(data); }
        @Override public byte[] wireEncode(LargeMessage msg) { return LargeMessage.ADAPTER.encode(msg); }
        @Override public LargeMessage jsonDecode(String text) throws Exception { return LARGE_JSON.fromJson(text); }
        @Override public String jsonEncode(LargeMessage msg) { return LARGE_JSON.toJson(msg); }
        @Override public long scalar(LargeMessage msg) { return msg.source.length(); }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(LargeMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(LargeMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    public static void main(String[] args) throws Exception {
        new Bench().run(args);
    }
}
