package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
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
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.ContextCompat;
import androidx.core.content.FileProvider;

import java.io.File;

public class MainActivity extends Activity {
    private static final String TERMUX = "com.termux";
    private static final String X11 = "com.termux.x11";
    private static final String RUN_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final int REQ_RUN_PERMISSION = 2001;
    private static final int REQ_UNKNOWN_SOURCES = 2002;
    private static final int REQ_NOTIFICATIONS = 2003;

    private static final String ENABLE_EXTERNAL_COMMAND =
            "for f in \"$HOME/.termux/termux.properties\" \"$HOME/.config/termux/termux.properties\"; do " +
            "mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; " +
            "if grep -q '^[[:space:]]*allow-external-apps=' \"$f\"; then " +
            "sed -i 's/^[[:space:]]*allow-external-apps=.*/allow-external-apps=true/' \"$f\"; " +
            "else printf '\\nallow-external-apps=true\\n' >> \"$f\"; fi; chmod 600 \"$f\"; done; " +
            "termux-reload-settings 2>/dev/null || true; " +
            "echo '=== deskTAB Termux 설정 확인 ==='; " +
            "grep -H '^[[:space:]]*allow-external-apps=' \"$HOME/.termux/termux.properties\" \"$HOME/.config/termux/termux.properties\" 2>/dev/null; " +
            "echo '두 줄 모두 allow-external-apps=true 이면 완료입니다.'";

    private static final String MANUAL_BOOTSTRAP_COMMAND =
            "curl -fL --retry 5 https://raw.githubusercontent.com/KKomaProgrammer/deskTAB-chrome/main/app/src/main/assets/bootstrap.sh | bash";

    private TextView status, progressDetail;
    private ProgressBar progressBar;
    private android.content.SharedPreferences prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private final Runnable uiTicker = new Runnable() {
        @Override public void run() {
            refreshStatus();
            handler.postDelayed(this, 1000);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("state", MODE_PRIVATE);
        SetupService.createChannel(this);

        if (prefs.getBoolean("setup_running", false)
                && prefs.getInt("setup_engine_version", 0) < SetupService.ENGINE_VERSION) {
            prefs.edit()
                    .putBoolean("setup_running", false)
                    .putInt("setup_progress", 0)
                    .putString("setup_stage", "이전 연결 방식 초기화 · 새 전면 Activity 브리지 사용 가능")
                    .putString("termux_last_error", "")
                    .putLong("setup_eta_base", 0)
                    .apply();
        }

        setContentView(buildUi());
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, REQ_NOTIFICATIONS);
        }
        refreshStatus();
    }

    @Override protected void onStart() {
        super.onStart();
        handler.removeCallbacks(uiTicker);
        handler.post(uiTicker);
    }

    @Override protected void onStop() {
        handler.removeCallbacks(uiTicker);
        super.onStop();
    }

    @Override protected void onResume() {
        super.onResume();
        refreshStatus();
        if (prefs.getBoolean("install_flow", false)) {
            getWindow().getDecorView().postDelayed(this::continueDependencyInstall, 500);
        }
    }

    private View buildUi() {
        int pad = dp(20);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("deskTAB Chrome");
        title.setTextSize(30);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("Android 안에서 Termux + Ubuntu + Termux:X11 + 데스크톱 Google Chrome 실행");
        subtitle.setTextSize(15);
        subtitle.setPadding(0, dp(8), 0, dp(18));
        root.addView(subtitle);

        status = new TextView(this);
        status.setTextSize(14);
        status.setPadding(dp(14), dp(14), dp(14), dp(14));
        status.setBackgroundColor(0xFFF1F3F4);
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        LinearLayout.LayoutParams pp = new LinearLayout.LayoutParams(-1, dp(18));
        pp.topMargin = dp(14);
        root.addView(progressBar, pp);

        progressDetail = new TextView(this);
        progressDetail.setTextSize(13);
        progressDetail.setPadding(0, dp(6), 0, dp(6));
        root.addView(progressDetail);

        root.addView(button("1. 필수 앱 다운로드/설치", v -> startDependencyInstall()));
        root.addView(button("2. Termux 연결 허용", v -> enableTermuxIntegration()));
        root.addView(button("3. Ubuntu + Chrome 고속 설정", v -> runBootstrap()));
        root.addView(button("Desktop Chrome 실행", v -> launchDesktopChrome()));
        root.addView(button("세션 종료", v -> stopDesktop()));

        TextView note = new TextView(this);
        note.setText("v1.2.4부터 설치 버튼을 누른 화면(Activity)에서 Termux를 직접 호출합니다. 5초 안에 app-shell이 시작되지 않으면 보이는 terminal-session 방식으로 자동 재시도합니다. 두 방식 모두 stdin에 의존하지 않고 동일한 bootstrap 명령을 실행하며, X11 패키지가 준비되는 즉시 :1 서버도 자동 시작합니다.");
        note.setTextSize(13);
        note.setPadding(0, dp(20), 0, dp(8));
        root.addView(note);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        return scroll;
    }

    private Button button(String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(54));
        lp.topMargin = dp(12);
        b.setLayoutParams(lp);
        return b;
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

    private void refreshStatus() {
        if (status == null) return;
        boolean termux = installed(TERMUX);
        boolean x11 = installed(X11);
        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;
        boolean ready = prefs.getBoolean("ready", false);
        boolean running = prefs.getBoolean("setup_running", false);
        int sp = ready ? 100 : prefs.getInt("setup_progress", 0);
        String stage = ready ? "설정 완료"
                : prefs.getString("setup_stage", running ? "고속 설정 진행 중" : "설정 필요");
        long eta = running ? SetupService.remainingEta(prefs) : 0;
        boolean depRunning = prefs.getBoolean("dep_download_running", false);
        int depProgress = prefs.getInt("dep_progress", 0);
        String depStage = prefs.getString("dep_stage", "대기");
        String lastError = prefs.getString("termux_last_error", "");

        status.setText(
                "Termux: " + (termux ? "설치됨" : "미설치") +
                "\nTermux:X11: " + (x11 ? "설치됨" : "미설치") +
                "\nRUN_COMMAND 권한: " + (permission ? "허용됨" : "허용 필요") +
                "\nLinux 환경: " + (ready ? "설정 완료" : (running ? "고속 백그라운드 설정 중" : "설정 필요")) +
                "\n설치 엔진: " + (prefs.getInt("setup_engine_version", 0) >= SetupService.ENGINE_VERSION
                    ? "전면 Activity 브리지 v" + SetupService.ENGINE_VERSION : "대기") +
                "\n기기 ABI: " + Build.SUPPORTED_ABIS[0] +
                (!lastError.isEmpty() ? "\n최근 Termux 오류: " + lastError : ""));

        if (running || ready) {
            progressBar.setProgress(sp);
            progressDetail.setText("Linux 설정: " + sp + "% · " + stage
                    + (running ? "\n예상 남은 시간: " + SetupService.formatEta(eta) + " · 목표 전체 약 2~5분" : ""));
        } else if (depRunning || prefs.getBoolean("dep_download_ready", false)) {
            progressBar.setProgress(depProgress);
            progressDetail.setText("필수 앱 다운로드: " + depProgress + "% · " + depStage);
        } else {
            progressBar.setProgress(0);
            progressDetail.setText(stage);
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
            Toast.makeText(this, "deskTAB Chrome의 APK 설치 허용을 켜 주세요.", Toast.LENGTH_LONG).show();
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
        Toast.makeText(this, "필수 앱 설치가 완료되었습니다.", Toast.LENGTH_LONG).show();
        refreshStatus();
    }

    private void startDependencyDownload() {
        if (!prefs.getBoolean("dep_download_running", false)) {
            Intent i = new Intent(this, SetupService.class).setAction(SetupService.ACTION_DOWNLOAD_DEPS);
            ContextCompat.startForegroundService(this, i);
            Toast.makeText(this, "다운로드를 시작했습니다. 앱을 닫아도 계속됩니다.", Toast.LENGTH_LONG).show();
        } else {
            Toast.makeText(this, "필수 앱을 백그라운드에서 다운로드 중입니다.", Toast.LENGTH_SHORT).show();
        }
        refreshStatus();
    }

    private void installApk(File apk) {
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", apk);
        Intent i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(uri, "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        startActivity(i);
    }

    private void enableTermuxIntegration() {
        if (!installed(TERMUX)) {
            Toast.makeText(this, "먼저 Termux를 설치해 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
        }
        ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("deskTAB Termux setup", ENABLE_EXTERNAL_COMMAND));
        new AlertDialog.Builder(this)
                .setTitle("Termux 보안 설정 1회 필요")
                .setMessage("설정 명령을 복사했습니다. Termux에서 붙여넣고 Enter를 누르세요. 두 설정 경로에 모두 allow-external-apps=true를 적용합니다. v1.2.4에서는 실제 설치 명령은 deskTAB의 보이는 화면에서 직접 전달합니다.")
                .setPositiveButton("Termux 열기", (d,w) -> openPackage(TERMUX))
                .setNeutralButton("deskTAB 권한 설정", (d,w) -> openOwnAppSettings())
                .setNegativeButton("닫기", null)
                .show();
    }

    private void runBootstrap() {
        if (!installed(TERMUX) || !installed(X11)) {
            Toast.makeText(this, "필수 앱 설치부터 완료해 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        if (!Build.SUPPORTED_ABIS[0].contains("arm64")) {
            Toast.makeText(this, "현재 고속 이미지는 ARM64 기기를 지원합니다.", Toast.LENGTH_LONG).show();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            Toast.makeText(this, "RUN_COMMAND 권한을 허용한 뒤 다시 눌러 주세요.", Toast.LENGTH_LONG).show();
            return;
        }

        boolean runningCurrent = prefs.getBoolean("setup_running", false)
                && prefs.getInt("setup_engine_version", 0) == SetupService.ENGINE_VERSION;
        if (runningCurrent && prefs.getInt("setup_progress", 0) > 1) {
            Toast.makeText(this, "이미 고속 설치가 진행 중입니다.", Toast.LENGTH_LONG).show();
            return;
        }

        long now = System.currentTimeMillis();
        prefs.edit()
                .putBoolean("setup_running", true)
                .putBoolean("ready", false)
                .putInt("setup_engine_version", SetupService.ENGINE_VERSION)
                .putInt("setup_progress", 1)
                .putString("setup_stage", "deskTAB 화면에서 Termux 직접 호출 중")
                .putString("termux_last_error", "")
                .putLong("setup_eta_base", 300)
                .putLong("setup_eta_at", now)
                .putLong("setup_start", now)
                .apply();

        ContextCompat.startForegroundService(this,
                new Intent(this, SetupService.class).setAction(SetupService.ACTION_BOOTSTRAP));

        try {
            startBootstrapFromForegroundActivity(false);
            Toast.makeText(this, "Termux에 직접 설치 명령을 전달했습니다.", Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            prefs.edit().putString("termux_last_error", e.getClass().getSimpleName() + ": " + e.getMessage()).apply();
        }

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false)) return;
            if (prefs.getInt("setup_engine_version", 0) != SetupService.ENGINE_VERSION) return;
            if (prefs.getInt("setup_progress", 1) > 1) return;
            prefs.edit().putString("setup_stage", "app-shell 무응답 · 보이는 Termux 세션으로 자동 재시도").apply();
            try {
                startBootstrapFromForegroundActivity(true);
                Toast.makeText(MainActivity.this,
                        "백그라운드 호출이 막혀 보이는 Termux 세션으로 자동 재시도했습니다.",
                        Toast.LENGTH_LONG).show();
            } catch (Exception e) {
                prefs.edit().putString("termux_last_error", e.getClass().getSimpleName() + ": " + e.getMessage()).apply();
            }
        }, 5000);

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false)) return;
            if (prefs.getInt("setup_progress", 1) > 1) return;
            ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("deskTAB emergency bootstrap", MANUAL_BOOTSTRAP_COMMAND));
            prefs.edit().putString("setup_stage", "Android가 Termux API를 차단함 · 긴급 직접 실행 명령을 클립보드에 준비").apply();
        }, 12000);

        refreshStatus();
    }

    private void startBootstrapFromForegroundActivity(boolean visibleTerminal) {
        Intent callback = new Intent(this, TermuxResultService.class)
                .setAction(TermuxResultService.ACTION_BOOTSTRAP_RESULT);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_ONE_SHOT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) piFlags |= PendingIntent.FLAG_MUTABLE;
        PendingIntent resultIntent = PendingIntent.getService(this,
                visibleTerminal ? 4502 : 4501, callback, piFlags);

        Intent i = new Intent();
        i.setClassName(TERMUX, "com.termux.app.RunCommandService");
        i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash");
        i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[]{"-lc", MANUAL_BOOTSTRAP_COMMAND});
        i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        i.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", resultIntent);
        i.putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "deskTAB Linux setup");
        i.putExtra("com.termux.RUN_COMMAND_COMMAND_DESCRIPTION", "deskTAB Ubuntu/XFCE/Chrome runtime setup");

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

        android.content.ComponentName started = startService(i);
        if (started == null) throw new IllegalStateException("Termux RunCommandService returned null");
    }

    private void launchDesktopChrome() {
        if (!prefs.getBoolean("ready", false)) {
            Toast.makeText(this, "Linux 환경 설정을 먼저 완료해 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        openPackage(X11);
        getWindow().getDecorView().postDelayed(() -> {
            try {
                sendTermux("/data/data/com.termux/files/usr/bin/bash",
                        new String[]{"-lc", "exec \"$HOME/.desktab/launch.sh\""}, true);
                Toast.makeText(this, "데스크톱 Chrome을 시작합니다.", Toast.LENGTH_SHORT).show();
            } catch (Exception e) {
                showError("Chrome 실행 실패", e);
            }
        }, 650);
    }

    private void stopDesktop() {
        try {
            sendTermux("/data/data/com.termux/files/usr/bin/bash",
                    new String[]{"-lc", "proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'pkill -f google-chrome-stable || true; pkill -f xfce4-session || true' >/dev/null 2>&1 || true; pkill -f 'termux-x11 :1' || true"}, true);
            Toast.makeText(this, "데스크톱 세션 종료 명령을 보냈습니다.", Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            showError("세션 종료 실패", e);
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
        startService(i);
    }

    private void openPackage(String pkg) {
        Intent i = getPackageManager().getLaunchIntentForPackage(pkg);
        if (i != null) startActivity(i);
        else Toast.makeText(this, pkg + " 실행 화면을 찾지 못했습니다.", Toast.LENGTH_LONG).show();
    }

    private void openOwnAppSettings() {
        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName())));
    }

    private void showError(String title, Exception e) {
        new AlertDialog.Builder(this).setTitle(title)
                .setMessage(e.getClass().getSimpleName() + ": " + e.getMessage())
                .setPositiveButton("확인", null).show();
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_RUN_PERMISSION) {
            refreshStatus();
            if (grantResults.length == 0 || grantResults[0] != PackageManager.PERMISSION_GRANTED) {
                Toast.makeText(this,
                        "앱 정보 > 권한 > 추가 권한에서 Termux 명령 실행 권한을 허용해 주세요.",
                        Toast.LENGTH_LONG).show();
            }
        }
    }
}
