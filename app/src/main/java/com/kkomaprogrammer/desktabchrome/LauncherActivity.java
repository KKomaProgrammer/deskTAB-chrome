package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public class LauncherActivity extends Activity {
    private static final String TERMUX = "com.termux";
    private static final String X11 = "com.termux.x11";
    private static final String RUN_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final int REQ_RUN_PERMISSION = 4101;
    private static final int REQ_UNKNOWN_SOURCES = 4102;
    private static final int REQ_NOTIFICATIONS = 4103;
    private static final int ENGINE_VERSION = 11;
    private static final int DESKTOP_PATCH_VERSION = 5;

    private static final String TERMUX_BOOTSTRAP_PATH =
            "/data/data/com.termux/files/home/desktab-bootstrap.sh";
    private static final String TERMUX_HEARTBEAT_PATH =
            "/data/data/com.termux/files/home/.desktab/heartbeat";
    private static final String TERMUX_BRIDGE_PROBE =
            "/data/data/com.termux/files/home/.desktab/bridge-ok";

    private static final String ENABLE_EXTERNAL_COMMAND =
            "for f in \"$HOME/.termux/termux.properties\" \"$HOME/.config/termux/termux.properties\"; do " +
            "mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; " +
            "if grep -q '^[[:space:]]*allow-external-apps=' \"$f\"; then " +
            "sed -i 's/^[[:space:]]*allow-external-apps=.*/allow-external-apps=true/' \"$f\"; " +
            "else printf '\\nallow-external-apps=true\\n' >> \"$f\"; fi; chmod 600 \"$f\"; done; " +
            "termux-reload-settings >/dev/null 2>&1 || true; echo 'deskTAB 연결 완료'";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private android.content.SharedPreferences prefs;
    private TextView statusText;
    private TextView progressText;
    private ProgressBar progressBar;
    private Button primaryButton;

    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            syncHeartbeatFromTermux();
            refreshUi();
            handler.postDelayed(this, 1000);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("state", MODE_PRIVATE);
        SetupService.createChannel(this);

        if (prefs.getInt("launcher_patch_version", 0) < DESKTOP_PATCH_VERSION
                && !prefs.getBoolean("setup_running", false)) {
            prefs.edit()
                    .putInt("launcher_patch_version", DESKTOP_PATCH_VERSION)
                    .putBoolean("ready", false)
                    .putString("termux_last_error", "")
                    .apply();
        }

        setContentView(buildUi());
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, REQ_NOTIFICATIONS);
        }
        syncHeartbeatFromTermux();
        refreshUi();
    }

    @Override protected void onStart() {
        super.onStart();
        handler.removeCallbacks(ticker);
        handler.post(ticker);
    }

    @Override protected void onStop() {
        handler.removeCallbacks(ticker);
        super.onStop();
    }

    @Override protected void onResume() {
        super.onResume();
        if (prefs == null) return;
        if (prefs.getBoolean("install_flow", false)) {
            handler.postDelayed(this::continueDependencyInstall, 450);
        }
        if (installed(TERMUX) && checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED) {
            if (probeTermuxBridge()) {
                prefs.edit().putBoolean("termux_bridge_ready", true).apply();
                if (prefs.getBoolean("pending_setup_after_bridge", false)) {
                    prefs.edit().putBoolean("pending_setup_after_bridge", false).apply();
                    handler.postDelayed(this::runBootstrap, 300);
                }
            }
        }
        syncHeartbeatFromTermux();
        refreshUi();
    }

    private View buildUi() {
        int pad = dp(24);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, dp(22), pad, pad);
        root.setBackgroundColor(Color.rgb(250, 250, 250));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText("deskTAB Chrome");
        title.setTextSize(28);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(Color.rgb(32, 33, 36));
        header.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        Button settings = new Button(this);
        settings.setText("⚙");
        settings.setTextSize(22);
        settings.setAllCaps(false);
        settings.setGravity(Gravity.CENTER);
        settings.setPadding(0, 0, 0, 0);
        settings.setBackground(rounded(Color.rgb(232, 234, 237), 18));
        settings.setOnClickListener(v -> showSettings());
        header.addView(settings, new LinearLayout.LayoutParams(dp(52), dp(52)));
        root.addView(header);

        statusText = new TextView(this);
        statusText.setTextSize(15);
        statusText.setTextColor(Color.rgb(95, 99, 104));
        statusText.setPadding(0, dp(18), 0, dp(18));
        root.addView(statusText);

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setVisibility(View.GONE);
        root.addView(progressBar, new LinearLayout.LayoutParams(-1, dp(8)));

        progressText = new TextView(this);
        progressText.setTextSize(13);
        progressText.setTextColor(Color.rgb(95, 99, 104));
        progressText.setPadding(0, dp(8), 0, dp(18));
        progressText.setVisibility(View.GONE);
        root.addView(progressText);

        primaryButton = new Button(this);
        primaryButton.setAllCaps(false);
        primaryButton.setTextSize(18);
        primaryButton.setTextColor(Color.WHITE);
        primaryButton.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        primaryButton.setBackground(rounded(Color.rgb(26, 115, 232), 18));
        primaryButton.setOnClickListener(v -> onPrimaryAction());
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, dp(66));
        p.topMargin = dp(8);
        root.addView(primaryButton, p);
        return root;
    }

    private GradientDrawable rounded(int color, int radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        return d;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private boolean installed(String pkg) {
        try {
            getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private void refreshUi() {
        if (primaryButton == null) return;
        boolean termux = installed(TERMUX);
        boolean x11 = installed(X11);
        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;
        boolean bridge = prefs.getBoolean("termux_bridge_ready", false);
        boolean ready = prefs.getBoolean("ready", false);
        boolean running = prefs.getBoolean("setup_running", false);
        boolean depRunning = prefs.getBoolean("dep_download_running", false);
        String error = prefs.getString("termux_last_error", "");

        if (depRunning) {
            primaryButton.setText("필수 구성 다운로드 중…");
            primaryButton.setEnabled(false);
            progressBar.setVisibility(View.VISIBLE);
            progressText.setVisibility(View.VISIBLE);
            int p = prefs.getInt("dep_progress", 0);
            progressBar.setProgress(p);
            progressText.setText(p + "% · " + prefs.getString("dep_stage", "다운로드 중"));
            statusText.setText("처음 한 번만 필요한 구성요소를 준비하고 있습니다.");
            return;
        }

        if (running) {
            primaryButton.setText("설정 중…");
            primaryButton.setEnabled(false);
            progressBar.setVisibility(View.VISIBLE);
            progressText.setVisibility(View.VISIBLE);
            int p = prefs.getInt("setup_progress", 1);
            progressBar.setProgress(Math.max(0, p));
            progressText.setText(Math.max(0, p) + "% · " + prefs.getString("setup_stage", "설정 중"));
            statusText.setText("앱을 닫아도 설정은 계속됩니다.");
            return;
        }

        primaryButton.setEnabled(true);
        progressBar.setVisibility(View.GONE);
        progressText.setVisibility(View.GONE);

        if (!termux || !x11) {
            primaryButton.setText("필수 구성 설치");
            statusText.setText("처음 한 번만 설치하면 됩니다.");
        } else if (!permission || !bridge) {
            primaryButton.setText("Termux 연결");
            statusText.setText("한 번만 연결하면 이후에는 자동으로 실행됩니다.");
        } else if (!ready) {
            primaryButton.setText("초기 설정 시작");
            statusText.setText(error.isEmpty() ? "Linux 환경을 준비합니다." : "설정을 다시 확인해야 합니다.");
        } else {
            primaryButton.setText("Desktop Chrome 실행");
            statusText.setText("준비 완료");
        }
    }

    private void onPrimaryAction() {
        if (!installed(TERMUX) || !installed(X11)) {
            startDependencyInstall();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            return;
        }
        if (!prefs.getBoolean("termux_bridge_ready", false)) {
            connectTermux(true);
            return;
        }
        if (!prefs.getBoolean("ready", false)) {
            runBootstrap();
            return;
        }
        launchDesktopChrome();
    }

    private void showSettings() {
        String[] items = {
                "필수 구성 설치/복구",
                "Termux 연결",
                "Linux 환경 복구",
                "데스크톱 세션 종료",
                "진단"
        };
        new AlertDialog.Builder(this)
                .setTitle("설정")
                .setItems(items, (d, which) -> {
                    switch (which) {
                        case 0: startDependencyInstall(); break;
                        case 1: connectTermux(false); break;
                        case 2:
                            prefs.edit().putBoolean("ready", false).putString("termux_last_error", "").apply();
                            runBootstrap();
                            break;
                        case 3: stopDesktop(); break;
                        case 4: showDiagnostics(); break;
                    }
                })
                .setNegativeButton("닫기", null)
                .show();
    }

    private void showDiagnostics() {
        String error = prefs.getString("termux_last_error", "");
        String text = "Termux: " + (installed(TERMUX) ? "정상" : "설치 필요") +
                "\nTermux:X11: " + (installed(X11) ? "정상" : "설치 필요") +
                "\n명령 권한: " + (checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED ? "정상" : "허용 필요") +
                "\n연결: " + (prefs.getBoolean("termux_bridge_ready", false) ? "정상" : "확인 필요") +
                "\nLinux: " + (prefs.getBoolean("ready", false) ? "준비 완료" : "설정 필요") +
                (error.isEmpty() ? "" : "\n\n최근 오류:\n" + error);
        new AlertDialog.Builder(this).setTitle("진단").setMessage(text)
                .setPositiveButton("닫기", null).show();
    }

    private void connectTermux(boolean continueSetup) {
        if (!installed(TERMUX)) {
            startDependencyInstall();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            return;
        }
        if (probeTermuxBridge()) {
            prefs.edit().putBoolean("termux_bridge_ready", true).apply();
            Toast.makeText(this, "Termux 연결 완료", Toast.LENGTH_SHORT).show();
            if (continueSetup && !prefs.getBoolean("ready", false)) runBootstrap();
            refreshUi();
            return;
        }

        prefs.edit().putBoolean("pending_setup_after_bridge", continueSetup).apply();
        ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("deskTAB 연결", ENABLE_EXTERNAL_COMMAND));
        Toast.makeText(this, "Termux에서 붙여넣기 → Enter만 누른 뒤 deskTAB으로 돌아오세요.", Toast.LENGTH_LONG).show();
        openPackage(TERMUX);
    }

    private boolean probeTermuxBridge() {
        try (OutputStream out = getContentResolver().openOutputStream(termuxFileUri(TERMUX_BRIDGE_PROBE), "wt")) {
            if (out == null) return false;
            out.write("ok\n".getBytes(StandardCharsets.UTF_8));
            out.flush();
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    private void startDependencyInstall() {
        prefs.edit().putBoolean("install_flow", true).apply();
        continueDependencyInstall();
    }

    private void continueDependencyInstall() {
        if (!prefs.getBoolean("install_flow", false)) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && !getPackageManager().canRequestPackageInstalls()) {
            startActivityForResult(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName())), REQ_UNKNOWN_SOURCES);
            return;
        }

        File dir = new File(getCacheDir(), "apks");
        if (!installed(TERMUX)) {
            File apk = new File(dir, "termux.apk");
            if (apk.isFile()) { installApk(apk); return; }
            startDependencyDownload();
            return;
        }
        if (!installed(X11)) {
            File apk = new File(dir, "termux-x11.apk");
            if (apk.isFile()) { installApk(apk); return; }
            startDependencyDownload();
            return;
        }

        prefs.edit().putBoolean("install_flow", false)
                .putBoolean("dep_download_ready", false).apply();
        refreshUi();
        connectTermux(true);
    }

    private void startDependencyDownload() {
        if (!prefs.getBoolean("dep_download_running", false)) {
            ContextCompat.startForegroundService(this,
                    new Intent(this, SetupService.class).setAction(SetupService.ACTION_DOWNLOAD_DEPS));
        }
        refreshUi();
    }

    private void installApk(File apk) {
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", apk);
        Intent i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(uri, "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(i);
    }

    private void runBootstrap() {
        if (!installed(TERMUX) || !installed(X11)) {
            startDependencyInstall();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            return;
        }
        if (!probeTermuxBridge()) {
            prefs.edit().putBoolean("termux_bridge_ready", false).apply();
            connectTermux(true);
            return;
        }
        prefs.edit().putBoolean("termux_bridge_ready", true).apply();

        boolean alive = syncHeartbeatFromTermux();
        if (alive && prefs.getBoolean("setup_running", false)) {
            refreshUi();
            return;
        }

        try {
            installBootstrapIntoTermux();
        } catch (Exception e) {
            prefs.edit().putString("termux_last_error", "Termux 연결 실패: " + e.getMessage()).apply();
            refreshUi();
            return;
        }

        long now = System.currentTimeMillis();
        prefs.edit().putBoolean("setup_running", true)
                .putBoolean("ready", false)
                .putInt("setup_engine_version", ENGINE_VERSION)
                .putInt("setup_progress", 1)
                .putString("setup_stage", "설정 시작")
                .putString("termux_last_error", "")
                .putLong("setup_eta_base", 300)
                .putLong("setup_eta_at", now)
                .putLong("setup_start", now).apply();
        ContextCompat.startForegroundService(this, new Intent(this, SetupService.class));

        try { startLocalBootstrap(false); }
        catch (Exception e) { prefs.edit().putString("termux_last_error", e.getMessage()).apply(); }

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false) || syncHeartbeatFromTermux()
                    || prefs.getInt("setup_progress", 1) > 1) return;
            try { startLocalBootstrap(true); }
            catch (Exception e) { prefs.edit().putString("termux_last_error", e.getMessage()).apply(); }
        }, 7000);

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false) || syncHeartbeatFromTermux()
                    || prefs.getInt("setup_progress", 1) > 1) return;
            ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("deskTAB setup", "bash \"$HOME/desktab-bootstrap.sh\""));
            prefs.edit().putBoolean("setup_running", false)
                    .putString("termux_last_error", "자동 실행이 차단되었습니다. Termux에서 복사된 명령을 실행하세요.")
                    .apply();
            openPackage(TERMUX);
            Toast.makeText(this, "Termux에서 붙여넣기 → Enter만 누르세요.", Toast.LENGTH_LONG).show();
        }, 18000);
        refreshUi();
    }

    private void installBootstrapIntoTermux() throws Exception {
        byte[] bytes;
        try (InputStream in = getAssets().open("bootstrap-v15.sh");
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            bytes = out.toByteArray();
        }
        try (OutputStream out = getContentResolver().openOutputStream(termuxFileUri(TERMUX_BOOTSTRAP_PATH), "wt")) {
            if (out == null) throw new IllegalStateException("Termux 파일 연결 실패");
            out.write(bytes);
            out.flush();
        }
    }

    private Uri termuxFileUri(String path) {
        return new Uri.Builder().scheme("content").authority("com.termux.files").path(path).build();
    }

    private boolean syncHeartbeatFromTermux() {
        try (InputStream in = getContentResolver().openInputStream(termuxFileUri(TERMUX_HEARTBEAT_PATH))) {
            if (in == null) return false;
            BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
            String line = r.readLine();
            if (line == null || line.trim().isEmpty()) return false;
            String[] parts = line.trim().split("\\|", 5);
            if (parts.length < 5) return false;
            long ts = Long.parseLong(parts[0]);
            int progress = Integer.parseInt(parts[2]);
            long eta = Long.parseLong(parts[3]);
            String stage = parts[4];
            if (Math.abs(System.currentTimeMillis() / 1000L - ts) > 25) return false;
            long now = System.currentTimeMillis();

            if (progress < 0) {
                prefs.edit().putBoolean("setup_running", false)
                        .putBoolean("ready", false)
                        .putString("setup_stage", stage)
                        .putString("termux_last_error", stage)
                        .putLong("setup_eta_base", 0).putLong("setup_eta_at", now).apply();
                return false;
            }
            if (progress >= 100) {
                prefs.edit().putBoolean("setup_running", false)
                        .putBoolean("ready", true)
                        .putInt("setup_progress", 100)
                        .putString("setup_stage", stage)
                        .putString("termux_last_error", "")
                        .putLong("setup_eta_base", 0).putLong("setup_eta_at", now).apply();
                return true;
            }
            int current = prefs.getInt("setup_progress", 0);
            if (progress < current) return true;
            prefs.edit().putBoolean("setup_running", true)
                    .putBoolean("ready", false)
                    .putInt("setup_engine_version", ENGINE_VERSION)
                    .putInt("setup_progress", progress)
                    .putString("setup_stage", stage)
                    .putString("termux_last_error", "")
                    .putLong("setup_eta_base", eta).putLong("setup_eta_at", now).apply();
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }

    private void startLocalBootstrap(boolean visibleTerminal) {
        Intent callback = new Intent(this, TermuxResultService.class)
                .setAction(TermuxResultService.ACTION_BOOTSTRAP_RESULT);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_ONE_SHOT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags |= PendingIntent.FLAG_MUTABLE;
        PendingIntent resultIntent = PendingIntent.getService(this,
                visibleTerminal ? 5602 : 5601, callback, flags);

        Intent i = new Intent();
        i.setClassName(TERMUX, "com.termux.app.RunCommandService");
        i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash");
        i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[]{TERMUX_BOOTSTRAP_PATH});
        i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        i.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", resultIntent);
        i.putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "deskTAB Setup");
        if (visibleTerminal) {
            i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", false);
            i.putExtra("com.termux.RUN_COMMAND_RUNNER", "terminal-session");
            i.putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0");
            i.putExtra("com.termux.RUN_COMMAND_SHELL_NAME", "deskTAB Setup");
            i.putExtra("com.termux.RUN_COMMAND_SHELL_CREATE_MODE", "always");
        } else {
            i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true);
            i.putExtra("com.termux.RUN_COMMAND_RUNNER", "app-shell");
        }
        if (startService(i) == null) throw new IllegalStateException("Termux 실행 실패");
    }

    private void launchDesktopChrome() {
        if (!prefs.getBoolean("ready", false)) {
            runBootstrap();
            return;
        }
        openPackage(X11);
        handler.postDelayed(() -> {
            try {
                sendTermux("/data/data/com.termux/files/usr/bin/bash",
                        new String[]{"-lc", "exec \"$HOME/.desktab/launch.sh\""}, true);
            } catch (Exception e) {
                prefs.edit().putString("termux_last_error", "Chrome 실행 실패: " + e.getMessage()).apply();
                refreshUi();
            }
        }, 650);
    }

    private void stopDesktop() {
        try {
            sendTermux("/data/data/com.termux/files/usr/bin/bash",
                    new String[]{"-lc", "if [ -x \"$HOME/.desktab/stop.sh\" ]; then exec \"$HOME/.desktab/stop.sh\"; else pkill -x termux-x11 || true; fi"}, true);
            Toast.makeText(this, "데스크톱을 종료했습니다.", Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            Toast.makeText(this, "종료 명령을 보내지 못했습니다.", Toast.LENGTH_LONG).show();
        }
    }

    private void sendTermux(String path, String[] args, boolean background) {
        Intent i = new Intent();
        i.setClassName(TERMUX, "com.termux.app.RunCommandService");
        i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", path);
        i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args);
        i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background);
        i.putExtra("com.termux.RUN_COMMAND_RUNNER", background ? "app-shell" : "terminal-session");
        if (startService(i) == null) throw new IllegalStateException("Termux 실행 실패");
    }

    private void openPackage(String pkg) {
        Intent i = getPackageManager().getLaunchIntentForPackage(pkg);
        if (i != null) startActivity(i);
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_RUN_PERMISSION) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                connectTermux(true);
            } else {
                Toast.makeText(this, "Termux 명령 권한을 허용해 주세요.", Toast.LENGTH_LONG).show();
            }
        }
        refreshUi();
    }
}
