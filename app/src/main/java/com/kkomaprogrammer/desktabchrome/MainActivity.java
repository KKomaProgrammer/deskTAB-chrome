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
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    private static final String TERMUX = "com.termux";
    private static final String X11 = "com.termux.x11";
    private static final String RUN_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final int REQ_RUN_PERMISSION = 2001;
    private static final int REQ_UNKNOWN_SOURCES = 2002;
    private static final int REQ_NOTIFICATIONS = 2003;
    private static final int ENGINE_VERSION = 5;
    private static final String TERMUX_BOOTSTRAP_PATH =
            "/data/data/com.termux/files/home/desktab-bootstrap.sh";

    private static final String ENABLE_EXTERNAL_COMMAND =
            "for f in \"$HOME/.termux/termux.properties\" \"$HOME/.config/termux/termux.properties\"; do " +
            "mkdir -p \"$(dirname \"$f\")\"; touch \"$f\"; " +
            "if grep -q '^[[:space:]]*allow-external-apps=' \"$f\"; then " +
            "sed -i 's/^[[:space:]]*allow-external-apps=.*/allow-external-apps=true/' \"$f\"; " +
            "else printf '\\nallow-external-apps=true\\n' >> \"$f\"; fi; chmod 600 \"$f\"; done; " +
            "termux-reload-settings 2>/dev/null || true; " +
            "echo '=== deskTAB Termux 설정 확인 ==='; " +
            "grep -H '^[[:space:]]*allow-external-apps=' \"$HOME/.termux/termux.properties\" \"$HOME/.config/termux/termux.properties\" 2>/dev/null";

    private static final String EMERGENCY_COMMAND =
            "bash \"$HOME/desktab-bootstrap.sh\"";

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
                && prefs.getInt("setup_engine_version", 0) < ENGINE_VERSION) {
            prefs.edit().putBoolean("setup_running", false)
                    .putInt("setup_progress", 0)
                    .putString("setup_stage", "이전 실행 방식 초기화 · Termux 로컬 파일 브리지 v5 준비")
                    .putString("termux_last_error", "")
                    .putLong("setup_eta_base", 0).apply();
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
        note.setText("v1.2.5부터 bootstrap을 인터넷 파이프로 실행하지 않습니다. deskTAB이 Termux 공식 파일 Provider를 통해 스크립트를 Termux 홈에 직접 저장하고 그 로컬 파일을 실행합니다. 같은 설치 명령을 Service와 Activity가 동시에 보내던 중복 실행도 제거했습니다.");
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
        String stage = ready ? "설정 완료" : prefs.getString("setup_stage", running ? "고속 설정 진행 중" : "설정 필요");
        long eta = running ? SetupService.remainingEta(prefs) : 0;
        boolean depRunning = prefs.getBoolean("dep_download_running", false);
        int depProgress = prefs.getInt("dep_progress", 0);
        String depStage = prefs.getString("dep_stage", "대기");
        String lastError = prefs.getString("termux_last_error", "");

        status.setText("Termux: " + (termux ? "설치됨" : "미설치") +
                "\nTermux:X11: " + (x11 ? "설치됨" : "미설치") +
                "\nRUN_COMMAND 권한: " + (permission ? "허용됨" : "허용 필요") +
                "\nLinux 환경: " + (ready ? "설정 완료" : (running ? "고속 백그라운드 설정 중" : "설정 필요")) +
                "\n설치 엔진: Termux 로컬 파일 브리지 v" + ENGINE_VERSION +
                "\n기기 ABI: " + Build.SUPPORTED_ABIS[0] +
                (!lastError.isEmpty() ? "\n최근 Termux 오류: " + lastError : ""));

        if (running || ready) {
            progressBar.setProgress(sp);
            progressDetail.setText("Linux 설정: " + sp + "% · " + stage +
                    (running ? "\n예상 남은 시간: " + SetupService.formatEta(eta) : ""));
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !getPackageManager().canRequestPackageInstalls()) {
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

        prefs.edit().putBoolean("install_flow", false).putBoolean("dep_download_ready", false).apply();
        Toast.makeText(this, "필수 앱 설치가 완료되었습니다.", Toast.LENGTH_LONG).show();
        refreshStatus();
    }

    private void startDependencyDownload() {
        if (!prefs.getBoolean("dep_download_running", false)) {
            ContextCompat.startForegroundService(this,
                    new Intent(this, SetupService.class).setAction(SetupService.ACTION_DOWNLOAD_DEPS));
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
                .setMessage("설정 명령을 복사했습니다. Termux에서 붙여넣고 Enter를 누르세요. v1.2.5의 3번 버튼은 이후 Termux 파일 Provider에 bootstrap을 직접 써서 설정 적용 여부까지 검증합니다.")
                .setPositiveButton("Termux 열기", (d,w) -> openPackage(TERMUX))
                .setNeutralButton("deskTAB 권한 설정", (d,w) -> openOwnAppSettings())
                .setNegativeButton("닫기", null).show();
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

        try {
            installBootstrapIntoTermux();
        } catch (Exception e) {
            String msg = "Termux 파일 브리지 실패: " + e.getClass().getSimpleName() + ": " + e.getMessage();
            prefs.edit().putString("termux_last_error", msg).putString("setup_stage", msg).apply();
            new AlertDialog.Builder(this).setTitle("Termux 연결 검증 실패")
                    .setMessage(msg + "\n\n2. Termux 연결 허용의 두 설정값이 true인지 확인한 뒤 다시 시도하세요.")
                    .setPositiveButton("확인", null).show();
            refreshStatus();
            return;
        }

        long now = System.currentTimeMillis();
        prefs.edit().putBoolean("setup_running", true).putBoolean("ready", false)
                .putInt("setup_engine_version", ENGINE_VERSION).putInt("setup_progress", 1)
                .putString("setup_stage", "bootstrap을 Termux 홈에 직접 저장 완료 · 실행 요청 중")
                .putString("termux_last_error", "")
                .putLong("setup_eta_base", 300).putLong("setup_eta_at", now).putLong("setup_start", now).apply();

        // 중요: ACTION_BOOTSTRAP을 사용하지 않는다. 그 액션은 구버전 SetupService가 다시
        // Termux 명령을 발사하므로 중복 실행이 생긴다. 무액션으로 진행 추적만 시작한다.
        ContextCompat.startForegroundService(this, new Intent(this, SetupService.class));

        try {
            startLocalBootstrap(false);
        } catch (Exception e) {
            prefs.edit().putString("termux_last_error", e.getClass().getSimpleName() + ": " + e.getMessage()).apply();
        }

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false) || prefs.getInt("setup_progress", 1) > 1) return;
            prefs.edit().putString("setup_stage", "백그라운드 실행 무응답 · 보이는 Termux 세션에서 로컬 스크립트 실행").apply();
            try {
                startLocalBootstrap(true);
            } catch (Exception e) {
                prefs.edit().putString("termux_last_error", e.getClass().getSimpleName() + ": " + e.getMessage()).apply();
            }
        }, 4000);

        handler.postDelayed(() -> {
            if (!prefs.getBoolean("setup_running", false) || prefs.getInt("setup_progress", 1) > 1) return;
            ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("deskTAB local bootstrap", EMERGENCY_COMMAND));
            prefs.edit().putString("setup_stage", "자동 실행 무응답 · 로컬 스크립트 직접 실행 명령 복사됨")
                    .putString("termux_last_error", "자동 실행 경로가 응답하지 않았습니다. Termux에서 bash ~/desktab-bootstrap.sh 를 실행하면 됩니다.").apply();
            openPackage(TERMUX);
        }, 10000);

        refreshStatus();
    }

    private void installBootstrapIntoTermux() throws Exception {
        byte[] bytes;
        try (InputStream in = getAssets().open("bootstrap.sh")) {
            bytes = new byte[in.available()];
            int offset = 0;
            while (offset < bytes.length) {
                int n = in.read(bytes, offset, bytes.length - offset);
                if (n < 0) break;
                offset += n;
            }
        }
        Uri uri = new Uri.Builder().scheme("content").authority("com.termux.files")
                .path(TERMUX_BOOTSTRAP_PATH).build();
        try (OutputStream out = getContentResolver().openOutputStream(uri, "wt")) {
            if (out == null) throw new IllegalStateException("Termux ContentProvider returned null output stream");
            out.write(bytes);
            out.flush();
        }
        prefs.edit().putString("setup_stage", "Termux 파일 Provider 쓰기 검증 성공").apply();
    }

    private void startLocalBootstrap(boolean visibleTerminal) {
        Intent callback = new Intent(this, TermuxResultService.class)
                .setAction(TermuxResultService.ACTION_BOOTSTRAP_RESULT);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_ONE_SHOT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags |= PendingIntent.FLAG_MUTABLE;
        PendingIntent resultIntent = PendingIntent.getService(this, visibleTerminal ? 4602 : 4601, callback, flags);

        Intent i = new Intent();
        i.setClassName(TERMUX, "com.termux.app.RunCommandService");
        i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash");
        i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[]{TERMUX_BOOTSTRAP_PATH});
        i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        i.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", resultIntent);
        i.putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "deskTAB Linux setup v5");
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
                Toast.makeText(this, "앱 정보 > 권한 > 추가 권한에서 Termux 명령 실행 권한을 허용해 주세요.", Toast.LENGTH_LONG).show();
            }
        }
    }
}
