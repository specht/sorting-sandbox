package sandbox.sorting;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/** Counts operations; in visual runs also remembers what was touched. Sandbox use only. */
public final class Probe {
    public int reads;
    public int writes;
    public int comparisons;
    private final boolean track;
    private final Map<String, TreeSet<Integer>> readMarks = new TreeMap<>();
    private final Map<String, TreeSet<Integer>> writeMarks = new TreeMap<>();

    public Probe(boolean track) {
        this.track = track;
    }

    void read(String label, int index) {
        reads++;
        if (track) readMarks.computeIfAbsent(label, k -> new TreeSet<>()).add(index);
    }

    void write(String label, int index) {
        writes++;
        if (track) writeMarks.computeIfAbsent(label, k -> new TreeSet<>()).add(index);
    }

    public void discardMarkers() {
        readMarks.clear();
        writeMarks.clear();
    }

    /** [{list, index}, …] of the reads since the last call. */
    public List<Map<String, Object>> takeReads() {
        return take(readMarks);
    }

    public List<Map<String, Object>> takeWrites() {
        return take(writeMarks);
    }

    private static List<Map<String, Object>> take(Map<String, TreeSet<Integer>> marks) {
        List<Map<String, Object>> result = new ArrayList<>();
        for (Map.Entry<String, TreeSet<Integer>> entry : marks.entrySet()) {
            for (int index : entry.getValue()) {
                Map<String, Object> marker = new TreeMap<>();
                marker.put("list", entry.getKey());
                marker.put("index", index);
                result.add(marker);
            }
        }
        marks.clear();
        return result;
    }

    public Map<String, Object> metrics() {
        Map<String, Object> result = new java.util.LinkedHashMap<>();
        result.put("reads", reads);
        result.put("writes", writes);
        result.put("comparisons", comparisons);
        result.put("score", reads + writes + comparisons);
        return result;
    }

    // Privileged access for the sandbox runtime -------------------------------------

    public static Elements elements(Probe probe, String label, int[] values, int[] origins) {
        return new Elements(probe, label, values, origins);
    }

    public static int key(Element element) {
        return element.key;
    }

    public static int[] keys(Elements elements) {
        int[] result = new int[elements.length];
        for (int i = 0; i < result.length; i++) result[i] = elements.items[i].key;
        return result;
    }

    public static int[] origins(Elements elements) {
        int[] result = new int[elements.length];
        for (int i = 0; i < result.length; i++) result[i] = elements.items[i].origin;
        return result;
    }
}
