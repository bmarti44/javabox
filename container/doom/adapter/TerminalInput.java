import doom.DoomMain;
import doom.event_t;
import doom.evtype_t;
import g.Signals.ScanCode;

import java.io.BufferedReader;
import java.util.HashMap;
import java.util.Map;

/**
 * TerminalInput — Reads key events from stdin via binary protocol.
 *
 * Protocol (each line from browser via PTY):
 *   \x01D<scancode_name>\n  -> keydown event
 *   \x01U<scancode_name>\n  -> keyup event
 *   \x01Q\n                 -> quit (returns from readInputLoop)
 *
 * Scancode names match ScanCode enum names (e.g., "SC_UP", "SC_SPACE").
 */
public class TerminalInput {

    private static final Map<String, ScanCode> SCAN_MAP = new HashMap<>();

    static {
        for (ScanCode sc : ScanCode.values()) {
            SCAN_MAP.put(sc.name(), sc);
        }
    }

    /**
     * Blocking input loop. Reads lines from stdin and posts events to Doom.
     * Returns when quit command (\x01Q) is received or stdin closes.
     */
    public static void readInputLoop(DoomMain<?, ?> doom, BufferedReader reader) {
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.length() < 2) continue;

                // Check for \x01 prefix (binary protocol marker)
                if (line.charAt(0) != '\u0001') continue;

                char cmd = line.charAt(1);
                switch (cmd) {
                    case 'D': { // keydown
                        String scName = line.substring(2);
                        ScanCode sc = SCAN_MAP.get(scName);
                        if (sc != null && sc != ScanCode.SC_NULL) {
                            doom.PostEvent(new event_t.keyevent_t(evtype_t.ev_keydown, sc));
                        }
                        break;
                    }
                    case 'U': { // keyup
                        String scName = line.substring(2);
                        ScanCode sc = SCAN_MAP.get(scName);
                        if (sc != null && sc != ScanCode.SC_NULL) {
                            doom.PostEvent(new event_t.keyevent_t(evtype_t.ev_keyup, sc));
                        }
                        break;
                    }
                    case 'Q': { // quit
                        return;
                    }
                }
            }
        } catch (Exception e) {
            System.err.println("[TerminalInput] Error: " + e.getMessage());
        }
    }
}
