package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.app.AlertDialog;
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
            "mkdir -p ~/.termux; touch ~/.termux/termux.properties; " +
            "if grep -q '^allow-external-apps=' ~/.termux/termux.properties; then sed -i 's/^allow-external-apps=.*/allow-external-apps=true/' ~/.termux/termux.properties; " +
            "else echo 'allow-external-apps=true' >> ~/.termux/termux.properties; fi; termux-reload-settings; echo 'deskTAB: external command access enabled'";

    private TextView status, progressDetail;
    private ProgressBar progressBar;
    private android.content.SharedPreferences prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable uiTicker = new Runnable() {
        @Override public void run() { refreshStatus(); handler.postDelayed(this, 1000); }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("state", MODE_PRIVATE);
        SetupService.createChannel(this);
        setContentView(buildUi());
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, REQ_NOTIFICATIONS);
        }
        refreshStatus();
    }

    @Override protected void onStart() { super.onStart(); handler.post(uiTicker); }
    @Override protected void onStop() { handler.removeCallbacks(uiTicker); super.onStop(); }

    @Override protected void onResume() {
        super.onResume();
        refreshStatus();
        if (prefs.getBoolean("install_flow", false)) getWindow().getDecorView().postDelayed(this::continueDependencyInstall, 500);
    }

    private View buildUi() {
        int pad = dp(20);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(pad, pad, pad, pad);
        TextView title = new TextView(this); title.setText("deskTAB Chrome"); title.setTextSize(30); title.setTypeface(Typeface.DEFAULT, Typeface.BOLD); root.addView(title);
        TextView subtitle = new TextView(this); subtitle.setText("Android 안에서 Termux + Ubuntu + Termux:X11 + 데스크톱 Google Chrome 실행"); subtitle.setTextSize(15); subtitle.setPadding(0, dp(8), 0, dp(18)); root.addView(subtitle);
        status = new TextView(this); status.setTextSize(14); status.setPadding(dp(14), dp(14), dp(14), dp(14)); status.setBackgroundColor(0xFFF1F3F4); root.addView(status, new LinearLayout.LayoutParams(-1, -2));
        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progressBar.setMax(100); LinearLayout.LayoutParams pp = new LinearLayout.LayoutParams(-1, dp(18)); pp.topMargin = dp(14); root.addView(progressBar, pp);
        progressDetail = new TextView(this); progressDetail.setTextSize(13); progressDetail.setPadding(0, dp(6), 0, dp(6)); root.addView(progressDetail);
        root.addView(button("1. 필수 앱 다운로드/설치", v -> startDependencyInstall()));
        root.addView(button("2. Termux 연결 허용", v -> enableTermuxIntegration()));
        root.addView(button("3. Ubuntu + Chrome 백그라운드 설정", v -> runBootstrap()));
        root.addView(button("Desktop Chrome 실행", v -> launchDesktopChrome()));
        root.addView(button("세션 종료", v -> stopDesktop()));
        TextView note = new TextView(this); note.setText("Linux 설정과 APK 다운로드는 앱을 닫아도 계속됩니다. 알림에서 진행률과 예상 남은 시간을 확인할 수 있습니다. 최초 전체 설정 예상은 보통 약 20~35분이며 네트워크와 기기 성능에 따라 달라집니다. APK 설치 확인과 Termux 외부 명령 허용은 Android 보안상 최초 1회 직접 승인해야 합니다."); note.setTextSize(13); note.setPadding(0, dp(20), 0, dp(8)); root.addView(note);
        ScrollView scroll = new ScrollView(this); scroll.addView(root); return scroll;
    }

    private Button button(String text, View.OnClickListener listener) {
        Button b = new Button(this); b.setText(text); b.setAllCaps(false); b.setGravity(Gravity.CENTER); b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, dp(54)); lp.topMargin = dp(12); b.setLayoutParams(lp); return b;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private boolean installed(String pkg) { try { getPackageManager().getPackageInfo(pkg, 0); return true; } catch (Exception e) { return false; } }

    private void refreshStatus() {
        if (status == null) return;
        boolean termux = installed(TERMUX), x11 = installed(X11);
        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;
        boolean ready = prefs.getBoolean("ready", false), running = prefs.getBoolean("setup_running", false);
        int sp = ready ? 100 : prefs.getInt("setup_progress", 0);
        String stage = ready ? "설정 완료" : prefs.getString("setup_stage", running ? "설정 진행 중" : "설정 필요");
        long eta = running ? SetupService.remainingEta(prefs) : 0;
        boolean depRunning = prefs.getBoolean("dep_download_running", false);
        int dp = prefs.getInt("dep_progress", 0); String ds = prefs.getString("dep_stage", "대기");
        status.setText("Termux: " + (termux ? "설치됨" : "미설치") + "\nTermux:X11: " + (x11 ? "설치됨" : "미설치") +
                "\nRUN_COMMAND 권한: " + (permission ? "허용됨" : "허용 필요") + "\nLinux 환경: " + (ready ? "설정 완료" : (running ? "백그라운드 설정 진행 중" : "설정 필요")) +
                "\n기기 ABI: " + Build.SUPPORTED_ABIS[0]);
        if (running || ready) {
            progressBar.setProgress(sp); progressDetail.setText("Linux 설정: " + sp + "% · " + stage + (running ? "\n예상 남은 시간: " + SetupService.formatEta(eta) + " · 최초 전체 예상 약 20~35분" : ""));
        } else if (depRunning || prefs.getBoolean("dep_download_ready", false)) {
            progressBar.setProgress(dp); progressDetail.setText("필수 앱 다운로드: " + dp + "% · " + ds);
        } else { progressBar.setProgress(0); progressDetail.setText("Linux 설정을 시작하면 여기에 단계별 진행률과 예상 시간이 표시됩니다."); }
    }

    private void startDependencyInstall() {
        prefs.edit().putBoolean("install_flow", true).apply();
        continueDependencyInstall();
    }

    private void continueDependencyInstall() {
        if (!prefs.getBoolean("install_flow", false)) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !getPackageManager().canRequestPackageInstalls()) {
            startActivityForResult(new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + getPackageName())), REQ_UNKNOWN_SOURCES);
            Toast.makeText(this, "deskTAB Chrome의 APK 설치 허용을 켜 주세요.", Toast.LENGTH_LONG).show(); return;
        }
        File dir = new File(getCacheDir(), "apks");
        if (!installed(TERMUX)) {
            File apk = new File(dir, "termux.apk");
            if (apk.isFile()) { installApk(apk); return; }
            startDependencyDownload(); return;
        }
        if (!installed(X11)) {
            File apk = new File(dir, "termux-x11.apk");
            if (apk.isFile()) { installApk(apk); return; }
            startDependencyDownload(); return;
        }
        prefs.edit().putBoolean("install_flow", false).putBoolean("dep_download_ready", false).apply();
        Toast.makeText(this, "필수 앱 설치가 완료되었습니다.", Toast.LENGTH_LONG).show(); refreshStatus();
    }

    private void startDependencyDownload() {
        if (!prefs.getBoolean("dep_download_running", false)) {
            Intent i = new Intent(this, SetupService.class).setAction(SetupService.ACTION_DOWNLOAD_DEPS);
            ContextCompat.startForegroundService(this, i);
            Toast.makeText(this, "다운로드를 시작했습니다. 앱을 닫아도 계속됩니다.", Toast.LENGTH_LONG).show();
        } else Toast.makeText(this, "필수 앱을 백그라운드에서 다운로드 중입니다.", Toast.LENGTH_SHORT).show();
        refreshStatus();
    }

    private void installApk(File apk) {
        Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".files", apk);
        Intent i = new Intent(Intent.ACTION_VIEW); i.setDataAndType(uri, "application/vnd.android.package-archive"); i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivity(i);
    }

    private void enableTermuxIntegration() {
        if (!installed(TERMUX)) { Toast.makeText(this, "먼저 Termux를 설치해 주세요.", Toast.LENGTH_LONG).show(); return; }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
        ClipboardManager cm = (ClipboardManager)getSystemService(CLIPBOARD_SERVICE); cm.setPrimaryClip(ClipData.newPlainText("deskTAB Termux setup", ENABLE_EXTERNAL_COMMAND));
        new AlertDialog.Builder(this).setTitle("Termux 보안 설정 1회 필요").setMessage("명령을 클립보드에 복사했습니다. Termux가 열리면 붙여넣고 Enter를 한 번 누르세요.")
                .setPositiveButton("Termux 열기", (d,w) -> openPackage(TERMUX)).setNeutralButton("앱 권한 설정", (d,w) -> openOwnAppSettings()).setNegativeButton("닫기", null).show();
    }

    private void runBootstrap() {
        if (!installed(TERMUX) || !installed(X11)) { Toast.makeText(this, "필수 앱 설치부터 완료해 주세요.", Toast.LENGTH_LONG).show(); return; }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) { requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION); Toast.makeText(this, "RUN_COMMAND 권한을 허용한 뒤 다시 눌러 주세요.", Toast.LENGTH_LONG).show(); return; }
        if (prefs.getBoolean("setup_running", false)) { Toast.makeText(this, "이미 백그라운드에서 Linux 환경을 설정 중입니다.", Toast.LENGTH_LONG).show(); return; }
        Intent i = new Intent(this, SetupService.class).setAction(SetupService.ACTION_BOOTSTRAP); ContextCompat.startForegroundService(this, i);
        Toast.makeText(this, "Linux 설정을 시작했습니다. 앱을 닫아도 계속됩니다. 예상 약 20~35분입니다.", Toast.LENGTH_LONG).show(); refreshStatus();
    }

    private void launchDesktopChrome() {
        if (!prefs.getBoolean("ready", false)) { Toast.makeText(this, "Linux 환경 설정을 먼저 완료해 주세요.", Toast.LENGTH_LONG).show(); return; }
        openPackage(X11);
        getWindow().getDecorView().postDelayed(() -> {
            try { sendTermux("/data/data/com.termux/files/usr/bin/bash", new String[]{"-lc", "exec \"$HOME/.desktab/launch.sh\""}, true); Toast.makeText(this, "데스크톱 Chrome을 시작합니다.", Toast.LENGTH_SHORT).show(); }
            catch (Exception e) { showError("Chrome 실행 실패", e); }
        }, 650);
    }

    private void stopDesktop() {
        try { sendTermux("/data/data/com.termux/files/usr/bin/bash", new String[]{"-lc", "proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'pkill -f google-chrome-stable || true; pkill -f xfce4-session || true' >/dev/null 2>&1 || true; pkill -f 'termux-x11 :1' || true"}, true); Toast.makeText(this, "데스크톱 세션 종료 명령을 보냈습니다.", Toast.LENGTH_SHORT).show(); }
        catch (Exception e) { showError("세션 종료 실패", e); }
    }

    private void sendTermux(String path, String[] args, boolean background) {
        Intent i = new Intent(); i.setClassName(TERMUX, "com.termux.app.RunCommandService"); i.setAction("com.termux.RUN_COMMAND");
        i.putExtra("com.termux.RUN_COMMAND_PATH", path); i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args); i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home"); i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background); startService(i);
    }
    private void openPackage(String pkg) { Intent i = getPackageManager().getLaunchIntentForPackage(pkg); if (i != null) startActivity(i); else Toast.makeText(this, pkg + " 실행 화면을 찾지 못했습니다.", Toast.LENGTH_LONG).show(); }
    private void openOwnAppSettings() { startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))); }
    private void showError(String title, Exception e) { new AlertDialog.Builder(this).setTitle(title).setMessage(e.getClass().getSimpleName() + ": " + e.getMessage()).setPositiveButton("확인", null).show(); }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_RUN_PERMISSION) { refreshStatus(); if (grantResults.length == 0 || grantResults[0] != PackageManager.PERMISSION_GRANTED) Toast.makeText(this, "앱 정보 > 권한 > 추가 권한에서 Termux 명령 실행 권한을 허용해 주세요.", Toast.LENGTH_LONG).show(); }
    }
}
