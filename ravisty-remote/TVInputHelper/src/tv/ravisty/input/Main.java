package tv.ravisty.input;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Shell-UID input bridge. Exists only while its owning ADB connection is open. */
public final class Main {
    private static final int INJECT_ASYNC = 0;

    public static void main(String[] args) throws Exception {
        PrintWriter output = new PrintWriter(System.out, true);
        Object inputManager;
        Method inject;
        try {
            Class<?> managerClass = Class.forName("android.hardware.input.InputManager");
            Method getInstance = managerClass.getDeclaredMethod("getInstance");
            getInstance.setAccessible(true);
            inputManager = getInstance.invoke(null);
            inject = managerClass.getMethod("injectInputEvent", InputEvent.class, int.class);
            inject.setAccessible(true);
        } catch (Throwable error) {
            output.println("ERR 0 INIT_" + rootCause(error).getClass().getSimpleName());
            return;
        }
        output.println("READY 1");
        try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in, "UTF-8"))) {
            CommandLine command;
            while ((command = readCommand(input)) != null) {
                if (command.tooLong) {
                    output.println("ERR 0 COMMAND_TOO_LONG");
                    continue;
                }
                String line = command.text.trim();
                if (line.equals("ping")) {
                    output.println("PONG");
                    continue;
                }
                if (line.equals("exit")) {
                    output.println("BYE");
                    return;
                }
                String[] fields = line.split("\\s+");
                if (fields.length != 3 || !fields[0].equals("key")) {
                    output.println("ERR 0 COMMAND");
                    continue;
                }
                long sequence;
                try {
                    sequence = Long.parseLong(fields[1]);
                    if (sequence < 1L || sequence > 4294967295L) {
                        output.println("ERR 0 SEQUENCE_RANGE");
                        continue;
                    }
                } catch (NumberFormatException error) {
                    output.println("ERR 0 SEQUENCE_FORMAT");
                    continue;
                }
                int keyCode;
                try {
                    keyCode = Integer.parseInt(fields[2]);
                    if (!isAllowedKey(keyCode)) {
                        output.println("ERR " + sequence + " KEY_NOT_ALLOWED");
                        continue;
                    }
                } catch (NumberFormatException error) {
                    output.println("ERR " + sequence + " KEY_FORMAT");
                    continue;
                }
                try {
                    long downTime = SystemClock.uptimeMillis();
                    KeyEvent down = new KeyEvent(downTime, downTime, KeyEvent.ACTION_DOWN,
                            keyCode, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                            InputDevice.SOURCE_KEYBOARD);
                    KeyEvent up = new KeyEvent(downTime, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP,
                            keyCode, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                            InputDevice.SOURCE_KEYBOARD);
                    boolean downAccepted = (Boolean) inject.invoke(inputManager, down, INJECT_ASYNC);
                    boolean upAccepted = (Boolean) inject.invoke(inputManager, up, INJECT_ASYNC);
                    if (downAccepted && upAccepted) output.println("OK " + sequence);
                    else output.println("ERR " + sequence + " INJECT_REJECTED");
                } catch (Throwable error) {
                    output.println("ERR " + sequence + " INPUT_" + rootCause(error).getClass().getSimpleName());
                }
            }
        }
    }

    private static final class CommandLine {
        final String text;
        final boolean tooLong;
        CommandLine(String text, boolean tooLong) {
            this.text = text;
            this.tooLong = tooLong;
        }
    }

    /** Consume oversized lines without ever accumulating more than 100 chars. */
    private static CommandLine readCommand(BufferedReader input) throws IOException {
        char[] characters = new char[100];
        int size = 0;
        boolean tooLong = false;
        boolean received = false;
        while (true) {
            int next = input.read();
            if (next == -1) {
                if (!received) return null;
                break;
            }
            received = true;
            if (next == '\n') break;
            if (next == '\r') continue;
            if (size < characters.length) characters[size++] = (char) next;
            else tooLong = true;
        }
        return new CommandLine(tooLong ? "" : new String(characters, 0, size), tooLong);
    }

    private static boolean isAllowedKey(int keyCode) {
        switch (keyCode) {
            case 0: // Harmless diagnostic key.
            case 3: case 4: // Home, Back.
            case 19: case 20: case 21: case 22: case 23: // D-pad.
            case 24: case 25: case 26: // Volume and Power.
            case 82: // Menu.
            case 85: case 86: case 87: case 88: case 89: case 90: // Media.
            case 126: case 127: case 164: case 165: // Play, Pause, Mute, Info.
                return true;
            default:
                return false;
        }
    }

    private static Throwable rootCause(Throwable error) {
        if (error instanceof InvocationTargetException && error.getCause() != null) {
            return error.getCause();
        }
        return error;
    }
}
