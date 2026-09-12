package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.Gravity;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/** One-time gate that stops the old v9 xz extractor before v10 starts. */
public class MigrationActivity extends Activity {
    private static final String TERMUX = "com.termux";
    private static final String RUN_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final int REQ_RUN_PERMISSION = 3010;
    private static final String HEARTBEAT_PATH =
            "/data/data/com.termux/files/home/.desktab/heartbeat";
    private static final String HEARTBEAT_STATE_PATH =
            "/data/data/com.termux/files/home/.desktab/heartbeat-state";
    private boolean migrationStarted = false;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        TextView t = new TextView(this);
        t.setText("deskTAB Chrome\n고속 해제 엔진 v10 적용 중…");
        t.setTextSize(20);
        t.setGravity(Gravity.CENTER);
        setContentView(t);

        SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
        boolean needsMigration = !p.getBoolean("migration_v10_done", false)
                && !p.getBoolean("ready", false);
        if (needsMigration && installed(TERMUX)
                && checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            return;
        }
        startMigration();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                                     int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_RUN_PERMISSION) startMigration();
    }

    private synchronized void startMigration() {
        if (migrationStarted) return;
        migrationStarted = true;
        new Thread(() -> {
            migrateIfNeeded();
            runOnUiThread(() -> {
                startActivity(new Intent(MigrationActivity.this, MainActivityV10.class));
                finish();
            });
        }, "desktab-v10-migration").start();
    }

    private void migrateIfNeeded() {
        SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
        if (p.getBoolean("migration_v10_done", false)) return;

        boolean ready = p.getBoolean("ready", false);
        if (!ready) {
            long pid = readHeartbeatPid();
            if (installed(TERMUX)
                    && checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED) {
                sendCleanup(pid);
                SystemClock.sleep(1400);
            }
            // Clear stale v9 state after the kill attempt, so MainActivity cannot mistake
            // a dead extractor for an active setup and refuse the v10 restart.
            clearTermuxStateFile(HEARTBEAT_PATH);
            clearTermuxStateFile(HEARTBEAT_STATE_PATH);
            p.edit()
                    .putBoolean("ready", false)
                    .putBoolean("setup_running", false)
                    .putInt("setup_engine_version", 10)
                    .putInt("setup_progress", 0)
                    .putString("setup_stage", "zstd 고속 해제 엔진 v10 준비 완료")
                    .putString("termux_last_error", "")
                    .putLong("setup_eta_base", 0)
                    .putLong("setup_eta_at", System.currentTimeMillis())
                    .apply();
        }
        p.edit().putBoolean("migration_v10_done", true).apply();
    }

    private boolean installed(String pkg) {
        try {
            getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private long readHeartbeatPid() {
        try (InputStream in = getContentResolver().openInputStream(termuxFileUri(HEARTBEAT_PATH))) {
            if (in == null) return 0;
            BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
            String line = r.readLine();
            if (line == null) return 0;
            String[] parts = line.trim().split("\\|", 5);
            if (parts.length < 2) return 0;
            return Long.parseLong(parts[1]);
        } catch (Exception ignored) {
            return 0;
        }
    }

    private void clearTermuxStateFile(String path) {
        try (OutputStream out = getContentResolver().openOutputStream(termuxFileUri(path), "wt")) {
            if (out != null) {
                out.write(new byte[0]);
                out.flush();
            }
        } catch (Exception ignored) {
        }
    }

    private Uri termuxFileUri(String path) {
        return new Uri.Builder().scheme("content").authority("com.termux.files")
                .path(path).build();
    }

    private void sendCleanup(long pid) {
        String command =
                "target=" + Math.max(0, pid) + "; " +
                "kill_tree(){ p=\"$1\"; for c in $(ps -A -o PID=,PPID= 2>/dev/null | awk -v q=\"$p\" '$2==q {print $1}'); do kill_tree \"$c\"; done; kill -TERM \"$p\" >/dev/null 2>&1 || true; }; " +
                "if [ \"$target\" -gt 1 ] 2>/dev/null; then kill_tree \"$target\"; fi; " +
                "sleep 1; self=$$; parent=$PPID; while read -r p pp args; do " +
                "[ -n \"$p\" ] || continue; [ \"$p\" = \"$self\" ] && continue; [ \"$p\" = \"$parent\" ] && continue; " +
                "case \"$args\" in *desktab-bootstrap.sh*|*runtime-arm64.tar.xz*|*runtime-arm64.tar.zst*) " +
                "case \"$args\" in *bash*|*tar*|*xz*|*zstd*) kill -TERM \"$p\" >/dev/null 2>&1 || true;; esac;; esac; " +
                "done < <(ps -A -o PID=,PPID=,ARGS= 2>/dev/null || true); " +
                "rm -rf \"$HOME/.desktab/bootstrap.lock\"; " +
                "rm -f \"$HOME/.desktab/heartbeat\" \"$HOME/.desktab/heartbeat-state\"";

        Intent i = new Intent();
        i.setClassName(TERMUX, "com.termux.app.RunCommandService");
        i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash");
        i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[]{"-lc", command});
        i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true);
        i.putExtra("com.termux.RUN_COMMAND_RUNNER", "app-shell");
        try {
            startService(i);
        } catch (Exception ignored) {
        }
    }
}
