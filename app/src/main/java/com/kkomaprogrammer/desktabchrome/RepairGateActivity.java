package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;

/** One-time upgrade gate for the direct-rootfs desktop repair. */
public final class RepairGateActivity extends Activity {
    private static final String MIGRATION_KEY = "boot_recovery_v125_done";

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        SharedPreferences prefs = getSharedPreferences("state", MODE_PRIVATE);

        if (!prefs.getBoolean(MIGRATION_KEY, false)) {
            prefs.edit()
                    .putBoolean(MIGRATION_KEY, true)
                    .putBoolean("ready", false)
                    .putBoolean("pending_setup_after_bridge", true)
                    .putBoolean("setup_running", false)
                    .putString("termux_last_error", "")
                    .putString("setup_stage", "기존 Ubuntu 데스크톱 직접 수리")
                    .apply();
        }

        Intent next = new Intent(this, LauncherActivity.class);
        next.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(next);
        finish();
    }
}
