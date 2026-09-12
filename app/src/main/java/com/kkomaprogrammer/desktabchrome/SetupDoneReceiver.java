package com.kkomaprogrammer.desktabchrome;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

public class SetupDoneReceiver extends BroadcastReceiver {
    private static final String PROGRESS = "com.kkomaprogrammer.desktabchrome.SETUP_PROGRESS";
    private static final String DONE = "com.kkomaprogrammer.desktabchrome.SETUP_DONE";
    private static final String FAILED = "com.kkomaprogrammer.desktabchrome.SETUP_FAILED";

    @Override public void onReceive(Context context, Intent intent) {
        if (intent == null || intent.getAction() == null) return;
        SharedPreferences p = context.getSharedPreferences("state", Context.MODE_PRIVATE);
        String action = intent.getAction();
        if (PROGRESS.equals(action)) {
            int progress = intent.getIntExtra("progress", p.getInt("setup_progress", 1));
            long eta = intent.getLongExtra("eta", 0);
            String stage = intent.getStringExtra("stage");
            if (stage == null) stage = "Linux 환경 설정 중";
            p.edit().putBoolean("setup_running", true).putInt("setup_progress", progress)
                    .putString("setup_stage", stage).putLong("setup_eta_base", eta)
                    .putLong("setup_eta_at", System.currentTimeMillis()).apply();
            SetupService.updateSetupNotification(context, progress, stage, eta);
        } else if (DONE.equals(action)) {
            p.edit().putBoolean("ready", true).putBoolean("setup_running", false)
                    .putInt("setup_progress", 100).putString("setup_stage", "설정 완료")
                    .putLong("setup_eta_base", 0).putLong("setup_eta_at", System.currentTimeMillis()).apply();
            SetupService.updateSetupNotification(context, 100, "설정 완료 · 이제 Desktop Chrome을 실행할 수 있습니다", 0);
            context.stopService(new Intent(context, SetupService.class));
        } else if (FAILED.equals(action)) {
            String stage = intent.getStringExtra("stage");
            if (stage == null) stage = "설정 실패";
            p.edit().putBoolean("setup_running", false).putString("setup_stage", stage).putLong("setup_eta_base", 0).apply();
            SetupService.updateSetupNotification(context, p.getInt("setup_progress", 0), stage, 0);
            context.stopService(new Intent(context, SetupService.class));
        }
    }
}
