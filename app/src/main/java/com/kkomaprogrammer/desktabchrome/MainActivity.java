package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.content.FileProvider;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

public class MainActivity extends Activity {
    private static final String TERMUX = "com.termux";
    private static final String X11 = "com.termux.x11";
    private static final String RUN_PERMISSION = "com.termux.permission.RUN_COMMAND";
    private static final int REQ_RUN_PERMISSION = 2001;
    private static final int REQ_UNKNOWN_SOURCES = 2002;

    private static final String ENABLE_EXTERNAL_COMMAND =
            "mkdir -p ~/.termux; touch ~/.termux/termux.properties; " +
            "if grep -q '^allow-external-apps=' ~/.termux/termux.properties; then " +
            "sed -i 's/^allow-external-apps=.*/allow-external-apps=true/' ~/.termux/termux.properties; " +
            "else echo 'allow-external-apps=true' >> ~/.termux/termux.properties; fi; " +
            "termux-reload-settings; echo 'deskTAB: external command access enabled'";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean downloading = new AtomicBoolean(false);
    private TextView status;
    private android.content.SharedPreferences prefs;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("state", MODE_PRIVATE);
        setContentView(buildUi());
        refreshStatus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshStatus();
        if (prefs.getBoolean("install_flow", false) && !downloading.get()) {
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

        root.addView(button("1. 필수 앱 자동 설치", v -> startDependencyInstall()));
        root.addView(button("2. Termux 연결 허용", v -> enableTermuxIntegration()));
        root.addView(button("3. Ubuntu + Chrome 자동 설정", v -> runBootstrap()));
        root.addView(button("Desktop Chrome 실행", v -> launchDesktopChrome()));
        root.addView(button("세션 종료", v -> stopDesktop()));

        TextView note = new TextView(this);
        note.setText("최초 설치에서는 Android가 APK 설치 확인과 Termux 외부 명령 허용을 사용자에게 직접 확인합니다. 그 이후에는 이 앱의 ‘Desktop Chrome 실행’만 누르면 됩니다. PRoot 환경 때문에 Chrome은 --no-sandbox로 실행됩니다.");
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
        } catch (PackageManager.NameNotFoundException e) {
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
        status.setText(
                "Termux: " + (termux ? "설치됨" : "미설치") + "\n" +
                "Termux:X11: " + (x11 ? "설치됨" : "미설치") + "\n" +
                "RUN_COMMAND 권한: " + (permission ? "허용됨" : "허용 필요") + "\n" +
                "Linux 환경: " + (ready ? "설정 완료" : (running ? "설정 진행 중" : "설정 필요")) + "\n" +
                "기기 ABI: " + Build.SUPPORTED_ABIS[0]);
    }

    private void startDependencyInstall() {
        prefs.edit().putBoolean("install_flow", true).apply();
        continueDependencyInstall();
    }

    private void continueDependencyInstall() {
        if (!prefs.getBoolean("install_flow", false) || downloading.get()) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !getPackageManager().canRequestPackageInstalls()) {
            Intent i = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + getPackageName()));
            startActivityForResult(i, REQ_UNKNOWN_SOURCES);
            Toast.makeText(this, "deskTAB Chrome의 APK 설치 허용을 켜 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        if (!installed(TERMUX)) {
            downloadTermux();
            return;
        }
        if (!installed(X11)) {
            downloadX11();
            return;
        }
        prefs.edit().putBoolean("install_flow", false).apply();
        refreshStatus();
        Toast.makeText(this, "필수 앱 설치가 완료되었습니다.", Toast.LENGTH_LONG).show();
    }

    private void downloadTermux() {
        downloading.set(true);
        status.setText("Termux 공식 APK 정보를 확인하고 있습니다...");
        executor.execute(() -> {
            try {
                String api = "https://api.github.com/repos/termux/termux-app/releases/latest";
                JSONObject release = new JSONObject(readUrl(api));
                JSONArray assets = release.getJSONArray("assets");
                String abiToken = abiToken();
                String fallback = null;
                String chosen = null;
                for (int i = 0; i < assets.length(); i++) {
                    JSONObject a = assets.getJSONObject(i);
                    String name = a.getString("name");
                    String url = a.getString("browser_download_url");
                    if (!name.endsWith(".apk") || !name.contains("termux-app_")) continue;
                    if (name.contains("_universal.apk")) fallback = url;
                    if (name.contains("_" + abiToken + ".apk")) {
                        chosen = url;
                        break;
                    }
                }
                if (chosen == null) chosen = fallback;
                if (chosen == null) throw new IllegalStateException("No compatible Termux APK found");
                File apk = downloadFile(chosen, "termux.apk");
                runOnUiThread(() -> {
                    downloading.set(false);
                    installApk(apk);
                });
            } catch (Exception e) {
                fail("Termux 다운로드 실패", e);
            }
        });
    }

    private void downloadX11() {
        downloading.set(true);
        status.setText("Termux:X11 공식 nightly APK를 다운로드하고 있습니다...");
        executor.execute(() -> {
            try {
                String url = "https://github.com/termux/termux-x11/releases/download/nightly/termux-x11-universal-debug.apk";
                File apk = downloadFile(url, "termux-x11.apk");
                runOnUiThread(() -> {
                    downloading.set(false);
                    installApk(apk);
                });
            } catch (Exception e) {
                fail("Termux:X11 다운로드 실패", e);
            }
        });
    }

    private String abiToken() {
        String abi = Build.SUPPORTED_ABIS[0].toLowerCase(Locale.US);
        if (abi.contains("arm64")) return "arm64-v8a";
        if (abi.contains("armeabi")) return "armeabi-v7a";
        if (abi.contains("x86_64")) return "x86_64";
        return "x86";
    }

    private String readUrl(String address) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(address).openConnection();
        c.setRequestProperty("Accept", "application/vnd.github+json");
        c.setRequestProperty("User-Agent", "deskTAB-Chrome");
        c.setConnectTimeout(20000);
        c.setReadTimeout(20000);
        try (BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream(), StandardCharsets.UTF_8))) {
            StringBuilder out = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) out.append(line);
            return out.toString();
        } finally {
            c.disconnect();
        }
    }

    private File downloadFile(String address, String name) throws Exception {
        File dir = new File(getCacheDir(), "apks");
        if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("Cannot create APK cache");
        File out = new File(dir, name);
        HttpURLConnection c = (HttpURLConnection) new URL(address).openConnection();
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent", "deskTAB-Chrome");
        c.setConnectTimeout(30000);
        c.setReadTimeout(60000);
        try (InputStream in = new BufferedInputStream(c.getInputStream());
             FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) >= 0) fos.write(buf, 0, n);
        } finally {
            c.disconnect();
        }
        return out;
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
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("deskTAB Termux setup", ENABLE_EXTERNAL_COMMAND));

        new AlertDialog.Builder(this)
                .setTitle("Termux 보안 설정 1회 필요")
                .setMessage("명령을 클립보드에 복사했습니다. Termux가 열리면 붙여넣고 Enter를 한 번 누르세요. 이 단계는 Termux가 외부 앱의 명령 실행을 기본 차단하기 때문에 필요합니다.")
                .setPositiveButton("Termux 열기", (d, w) -> openPackage(TERMUX))
                .setNeutralButton("앱 권한 설정", (d, w) -> openOwnAppSettings())
                .setNegativeButton("닫기", null)
                .show();
    }

    private void runBootstrap() {
        if (!installed(TERMUX) || !installed(X11)) {
            Toast.makeText(this, "필수 앱 설치부터 완료해 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        if (checkSelfPermission(RUN_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{RUN_PERMISSION}, REQ_RUN_PERMISSION);
            Toast.makeText(this, "RUN_COMMAND 권한을 허용한 뒤 다시 눌러 주세요.", Toast.LENGTH_LONG).show();
            return;
        }
        try {
            String script = readAsset("bootstrap.sh");
            prefs.edit().putBoolean("setup_running", true).putBoolean("ready", false).apply();
            sendTermux("/data/data/com.termux/files/usr/bin/bash", new String[]{"-s"}, script, true);
            Toast.makeText(this, "자동 설정을 시작했습니다. 다운로드가 있어 시간이 걸릴 수 있습니다.", Toast.LENGTH_LONG).show();
            refreshStatus();
        } catch (Exception e) {
            fail("설정 스크립트 실행 실패", e);
        }
    }

    private void launchDesktopChrome() {
        if (!installed(TERMUX) || !installed(X11)) {
            Toast.makeText(this, "필수 앱이 설치되지 않았습니다.", Toast.LENGTH_LONG).show();
            return;
        }
        openPackage(X11);
        getWindow().getDecorView().postDelayed(() -> {
            try {
                String cmd = "if [ -x \"$HOME/.desktab/launch.sh\" ]; then exec \"$HOME/.desktab/launch.sh\"; else echo 'deskTAB setup is not complete' >&2; exit 2; fi";
                sendTermux("/data/data/com.termux/files/usr/bin/bash", new String[]{"-lc", cmd}, null, true);
                Toast.makeText(this, "데스크톱 Chrome을 시작합니다.", Toast.LENGTH_SHORT).show();
            } catch (Exception e) {
                fail("Chrome 실행 실패", e);
            }
        }, 650);
    }

    private void stopDesktop() {
        try {
            String cmd = "proot-distro login ubuntu --shared-tmp -- /bin/bash -lc 'pkill -f google-chrome-stable || true; pkill -f xfce4-session || true' >/dev/null 2>&1 || true; pkill -f 'termux-x11 :1' || true";
            sendTermux("/data/data/com.termux/files/usr/bin/bash", new String[]{"-lc", cmd}, null, true);
            Toast.makeText(this, "데스크톱 세션 종료 명령을 보냈습니다.", Toast.LENGTH_SHORT).show();
        } catch (Exception e) {
            fail("세션 종료 실패", e);
        }
    }

    private void sendTermux(String path, String[] args, String stdin, boolean background) {
        Intent intent = new Intent();
        intent.setClassName(TERMUX, "com.termux.app.RunCommandService");
        intent.setAction("com.termux.RUN_COMMAND");
        intent.putExtra("com.termux.RUN_COMMAND_PATH", path);
        intent.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args);
        intent.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
        intent.putExtra("com.termux.RUN_COMMAND_BACKGROUND", background);
        if (stdin != null) intent.putExtra("com.termux.RUN_COMMAND_STDIN", stdin);
        startService(intent);
    }

    private String readAsset(String name) throws Exception {
        try (InputStream in = getAssets().open(name)) {
            byte[] bytes = new byte[8192];
            StringBuilder out = new StringBuilder();
            int n;
            while ((n = in.read(bytes)) > 0) out.append(new String(bytes, 0, n, StandardCharsets.UTF_8));
            return out.toString();
        }
    }

    private void openPackage(String pkg) {
        Intent i = getPackageManager().getLaunchIntentForPackage(pkg);
        if (i != null) startActivity(i);
        else Toast.makeText(this, pkg + " 실행 화면을 찾지 못했습니다.", Toast.LENGTH_LONG).show();
    }

    private void openOwnAppSettings() {
        Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName()));
        startActivity(i);
    }

    private void fail(String prefix, Exception e) {
        runOnUiThread(() -> {
            downloading.set(false);
            prefs.edit().putBoolean("setup_running", false).apply();
            refreshStatus();
            new AlertDialog.Builder(this)
                    .setTitle(prefix)
                    .setMessage(e.getClass().getSimpleName() + ": " + e.getMessage())
                    .setPositiveButton("확인", null)
                    .show();
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_RUN_PERMISSION) {
            refreshStatus();
            if (grantResults.length == 0 || grantResults[0] != PackageManager.PERMISSION_GRANTED) {
                Toast.makeText(this, "앱 정보 > 권한 > 추가 권한에서 Termux 명령 실행 권한을 허용해 주세요.", Toast.LENGTH_LONG).show();
            }
        }
    }
}
