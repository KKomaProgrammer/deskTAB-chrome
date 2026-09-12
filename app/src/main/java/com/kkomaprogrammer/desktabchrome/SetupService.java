package com.kkomaprogrammer.desktabchrome;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

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

public class SetupService extends Service {
    public static final String ACTION_BOOTSTRAP = "com.kkomaprogrammer.desktabchrome.action.BOOTSTRAP";
    public static final String ACTION_DOWNLOAD_DEPS = "com.kkomaprogrammer.desktabchrome.action.DOWNLOAD_DEPS";
    public static final String CHANNEL_ID = "desktab_setup";
    public static final int NOTIFICATION_ID = 4101;
    public static final int ENGINE_VERSION = 2;

    private static final String TERMUX = "com.termux";
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private PowerManager.WakeLock wakeLock;
    private android.os.Handler handler;

    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
            if (p.getBoolean("setup_running", false)) {
                updateSetupNotification(SetupService.this,
                        p.getInt("setup_progress", 1),
                        p.getString("setup_stage", "고속 Linux 환경 설정 중"),
                        remainingEta(p));
                handler.postDelayed(this, 5000);
            }
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        createChannel(this);
        handler = new android.os.Handler(getMainLooper());
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();
        if (ACTION_DOWNLOAD_DEPS.equals(action)) {
            startForeground(NOTIFICATION_ID, buildNotification(this, "필수 앱 다운로드", "다운로드 준비 중", 0, true, true));
            acquireWakeLock();
            executor.execute(this::downloadDependencies);
            return START_STICKY;
        }

        SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
        if (ACTION_BOOTSTRAP.equals(action)) {
            boolean alreadyFast = p.getBoolean("setup_running", false)
                    && p.getInt("setup_engine_version", 0) == ENGINE_VERSION;
            if (!alreadyFast) {
                long now = System.currentTimeMillis();
                p.edit()
                        .putBoolean("setup_running", true)
                        .putBoolean("ready", false)
                        .putInt("setup_engine_version", ENGINE_VERSION)
                        .putInt("setup_progress", 1)
                        .putString("setup_stage", "고속 설치 엔진 시작")
                        .putLong("setup_eta_base", 300)
                        .putLong("setup_eta_at", now)
                        .putLong("setup_start", now)
                        .apply();
                startForeground(NOTIFICATION_ID, buildNotification(this,
                        "Linux 고속 설정", "고속 설치 엔진 시작 · 1% · 목표 약 5분", 1, false, true));
                acquireWakeLock();
                handler.removeCallbacks(ticker);
                handler.post(ticker);
                executor.execute(this::startBootstrap);
            } else {
                startForeground(NOTIFICATION_ID, buildNotification(this,
                        "Linux 고속 설정",
                        p.getString("setup_stage", "고속 설치 계속 진행 중"),
                        p.getInt("setup_progress", 1), false, true));
                acquireWakeLock();
                handler.post(ticker);
            }
            return START_STICKY;
        }

        if (p.getBoolean("setup_running", false)) {
            startForeground(NOTIFICATION_ID, buildNotification(this,
                    "Linux 고속 설정",
                    p.getString("setup_stage", "고속 설치 계속 진행 중"),
                    p.getInt("setup_progress", 1), false, true));
            acquireWakeLock();
            handler.post(ticker);
            return START_STICKY;
        }

        stopSelf();
        return START_NOT_STICKY;
    }

    private void acquireWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) return;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "deskTAB:fast-setup");
        wakeLock.acquire(60L * 60L * 1000L);
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
    }

    private void startBootstrap() {
        try {
            String script = readAsset("bootstrap.sh");
            Intent i = new Intent();
            i.setClassName(TERMUX, "com.termux.app.RunCommandService");
            i.setAction("com.termux.RUN_COMMAND");
            i.putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash");
            i.putExtra("com.termux.RUN_COMMAND_ARGUMENTS", new String[]{"-s"});
            i.putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home");
            i.putExtra("com.termux.RUN_COMMAND_BACKGROUND", true);
            i.putExtra("com.termux.RUN_COMMAND_STDIN", script);
            startService(i);
        } catch (Exception e) {
            failSetup("고속 설정 시작 실패: " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    private void downloadDependencies() {
        SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
        try {
            p.edit().putBoolean("dep_download_running", true).putBoolean("dep_download_ready", false).apply();
            File dir = new File(getCacheDir(), "apks");
            if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("APK cache creation failed");

            if (!installed("com.termux")) {
                updateDep(2, "Termux 최신 버전 확인 중");
                JSONObject release = new JSONObject(readUrl("https://api.github.com/repos/termux/termux-app/releases/latest"));
                JSONArray assets = release.getJSONArray("assets");
                String token = abiToken();
                String chosen = null, fallback = null;
                long expected = -1, fallbackSize = -1;
                for (int n = 0; n < assets.length(); n++) {
                    JSONObject a = assets.getJSONObject(n);
                    String name = a.getString("name");
                    if (!name.endsWith(".apk") || !name.contains("termux-app_")) continue;
                    if (name.contains("_universal.apk")) {
                        fallback = a.getString("browser_download_url");
                        fallbackSize = a.optLong("size", -1);
                    }
                    if (name.contains("_" + token + ".apk")) {
                        chosen = a.getString("browser_download_url");
                        expected = a.optLong("size", -1);
                        break;
                    }
                }
                if (chosen == null) { chosen = fallback; expected = fallbackSize; }
                if (chosen == null) throw new IllegalStateException("Compatible Termux APK not found");
                downloadFile(chosen, new File(dir, "termux.apk"), expected, 5, 55, "Termux APK 다운로드");
            } else updateDep(55, "Termux 설치 확인 완료");

            if (!installed("com.termux.x11")) {
                downloadFile("https://github.com/termux/termux-x11/releases/download/nightly/termux-x11-universal-debug.apk",
                        new File(dir, "termux-x11.apk"), -1, 55, 44, "Termux:X11 APK 다운로드");
            } else updateDep(99, "Termux:X11 설치 확인 완료");

            p.edit().putBoolean("dep_download_running", false).putBoolean("dep_download_ready", true)
                    .putInt("dep_progress", 100).putString("dep_stage", "다운로드 완료 · 설치 승인 필요").apply();
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            nm.notify(NOTIFICATION_ID, buildNotification(this, "필수 앱 다운로드 완료",
                    "앱을 열어 Android 설치 화면을 승인하세요.", 100, false, false));
            stopForeground(STOP_FOREGROUND_DETACH);
            stopSelf();
        } catch (Exception e) {
            p.edit().putBoolean("dep_download_running", false)
                    .putString("dep_stage", "다운로드 실패: " + e.getMessage()).apply();
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            nm.notify(NOTIFICATION_ID, buildNotification(this, "필수 앱 다운로드 실패",
                    String.valueOf(e.getMessage()), 0, true, false));
            stopForeground(STOP_FOREGROUND_DETACH);
            stopSelf();
        } finally {
            releaseWakeLock();
        }
    }

    private boolean installed(String pkg) {
        try { getPackageManager().getPackageInfo(pkg, 0); return true; }
        catch (Exception e) { return false; }
    }

    private void updateDep(int progress, String stage) {
        getSharedPreferences("state", MODE_PRIVATE).edit()
                .putInt("dep_progress", progress).putString("dep_stage", stage).apply();
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.notify(NOTIFICATION_ID, buildNotification(this, "필수 앱 다운로드",
                stage + " · " + progress + "%", progress, false, true));
    }

    private void downloadFile(String address, File out, long expected, int base, int span, String stage) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(address).openConnection();
        c.setInstanceFollowRedirects(true);
        c.setRequestProperty("User-Agent", "deskTAB-Chrome");
        c.setConnectTimeout(30000);
        c.setReadTimeout(60000);
        long total = expected > 0 ? expected : c.getContentLengthLong();
        long done = 0;
        int last = -1;
        try (InputStream in = new BufferedInputStream(c.getInputStream());
             FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) >= 0) {
                fos.write(buf, 0, n);
                done += n;
                int inner = total > 0 ? (int)Math.min(100, done * 100 / total)
                        : Math.min(95, (int)(done / (1024L * 1024L)) * 3);
                int progress = Math.min(99, base + inner * span / 100);
                if (progress != last) { last = progress; updateDep(progress, stage); }
            }
        } finally { c.disconnect(); }
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
            StringBuilder b = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) b.append(line);
            return b.toString();
        } finally { c.disconnect(); }
    }

    private String readAsset(String name) throws Exception {
        try (InputStream in = getAssets().open(name)) {
            byte[] buf = new byte[8192];
            StringBuilder b = new StringBuilder();
            int n;
            while ((n = in.read(buf)) > 0) b.append(new String(buf, 0, n, StandardCharsets.UTF_8));
            return b.toString();
        }
    }

    private void failSetup(String message) {
        SharedPreferences p = getSharedPreferences("state", MODE_PRIVATE);
        p.edit().putBoolean("setup_running", false).putString("setup_stage", message)
                .putLong("setup_eta_base", 0).apply();
        updateSetupNotification(this, p.getInt("setup_progress", 0), message, 0);
        stopForeground(STOP_FOREGROUND_DETACH);
        stopSelf();
        releaseWakeLock();
    }

    public static void createChannel(Context context) {
        NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationChannel ch = new NotificationChannel(CHANNEL_ID,
                "deskTAB 설정 및 다운로드", NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("Linux 고속 설정과 필수 앱 다운로드 진행 상황");
        nm.createNotificationChannel(ch);
    }

    private static PendingIntent contentIntent(Context c) {
        Intent i = new Intent(c, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(c, 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static Notification buildNotification(Context c, String title, String text,
                                                   int progress, boolean indeterminate, boolean ongoing) {
        Notification.Builder b = new Notification.Builder(c, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_launcher)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(contentIntent(c))
                .setOnlyAlertOnce(true)
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setStyle(new Notification.BigTextStyle().bigText(text));
        if (ongoing) b.setProgress(100, Math.max(0, Math.min(100, progress)), indeterminate);
        return b.build();
    }

    public static long remainingEta(SharedPreferences p) {
        long base = p.getLong("setup_eta_base", 0);
        long at = p.getLong("setup_eta_at", System.currentTimeMillis());
        if (base <= 0) return 0;
        return Math.max(0, base - Math.max(0, (System.currentTimeMillis() - at) / 1000L));
    }

    public static String formatEta(long sec) {
        if (sec <= 0) return "잠시 후";
        if (sec < 60) return "약 " + Math.max(1, sec) + "초";
        long m = (sec + 59) / 60;
        return "약 " + m + "분";
    }

    public static void updateSetupNotification(Context c, int progress, String stage, long eta) {
        createChannel(c);
        String text = stage + " · " + progress + "%"
                + (eta > 0 ? " · " + formatEta(eta) + " 남음" : "");
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        nm.notify(NOTIFICATION_ID, buildNotification(c,
                progress >= 100 ? "Linux 고속 설정 완료" : "Linux 고속 설정",
                text, progress, false, progress < 100));
    }

    @Override public void onDestroy() {
        handler.removeCallbacks(ticker);
        releaseWakeLock();
        executor.shutdownNow();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
