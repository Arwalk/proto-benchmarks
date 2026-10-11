package io.protobench;

import com.google.protobuf.RuntimeVersion;
import com.google.protobuf.util.JsonFormat;
import io.protobench.bench.LargeMessage;
import io.protobench.bench.MediumMessage;
import io.protobench.bench.SmallMessage;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;

/** proto-benchmarks harness: official protobuf-java runtime + protobuf-java-util JsonFormat. */
public final class Bench extends Harness {
    // Immutable, thread-safe; created once and reused as documented.
    static final JsonFormat.Printer PRINTER = JsonFormat.printer().omittingInsignificantWhitespace();
    static final JsonFormat.Parser PARSER = JsonFormat.parser();

    @Override protected String language() { return "java"; }
    @Override protected String name() { return "protobuf-java"; }

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
        return RuntimeVersion.MAJOR + "." + RuntimeVersion.MINOR + "." + RuntimeVersion.PATCH + RuntimeVersion.SUFFIX;
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
        @Override public SmallMessage wireDecode(byte[] data) throws Exception { return SmallMessage.parseFrom(data); }
        @Override public byte[] wireEncode(SmallMessage msg) { return msg.toByteArray(); }
        @Override public SmallMessage jsonDecode(String text) throws Exception {
            SmallMessage.Builder b = SmallMessage.newBuilder();
            PARSER.merge(text, b);
            return b.build();
        }
        @Override public String jsonEncode(SmallMessage msg) throws Exception { return PRINTER.print(msg); }
        @Override public long scalar(SmallMessage msg) { return msg.getId(); }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(SmallMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(SmallMessage msg, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    static final class Medium extends Dataset<MediumMessage> {
        @Override public MediumMessage wireDecode(byte[] data) throws Exception { return MediumMessage.parseFrom(data); }
        @Override public byte[] wireEncode(MediumMessage msg) { return msg.toByteArray(); }
        @Override public MediumMessage jsonDecode(String text) throws Exception {
            MediumMessage.Builder b = MediumMessage.newBuilder();
            PARSER.merge(text, b);
            return b.build();
        }
        @Override public String jsonEncode(MediumMessage msg) throws Exception { return PRINTER.print(msg); }
        @Override public long scalar(MediumMessage msg) { return msg.getCreatedAt(); }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(MediumMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(MediumMessage msg, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    static final class Large extends Dataset<LargeMessage> {
        @Override public LargeMessage wireDecode(byte[] data) throws Exception { return LargeMessage.parseFrom(data); }
        @Override public byte[] wireEncode(LargeMessage msg) { return msg.toByteArray(); }
        @Override public LargeMessage jsonDecode(String text) throws Exception {
            LargeMessage.Builder b = LargeMessage.newBuilder();
            PARSER.merge(text, b);
            return b.build();
        }
        @Override public String jsonEncode(LargeMessage msg) throws Exception { return PRINTER.print(msg); }
        @Override public long scalar(LargeMessage msg) { return msg.getSource().length(); }

        @Override public void wireDecodeLoop(byte[] data, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(wireDecode(data));
        }
        @Override public void wireEncodeLoop(LargeMessage msg, int n) {
            for (int i = 0; i < n; i++) sink ^= wireEncode(msg).length;
        }
        @Override public void jsonDecodeLoop(String text, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= scalar(jsonDecode(text));
        }
        @Override public void jsonEncodeLoop(LargeMessage msg, int n) throws Exception {
            for (int i = 0; i < n; i++) sink ^= jsonEncode(msg).length();
        }
    }

    public static void main(String[] args) throws Exception {
        new Bench().run(args);
    }
}
