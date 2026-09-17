package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;

/**
 * One-time upgrade gate for v1.2.23.
 *
 * v1.2.21/22 could leave a ready=true marker while the generated X11 launcher itself
 * was no longer usable.  The launcher marker therefore cannot be trusted for this
 * upgrade.  We invalidate it once, request the existing local bootstrap/repair flow,
 * then immediately hand control to the normal UI.  No Ubuntu/Chrome user data is
 * deleted: bootstrap-v16.sh detects the existing rootfs and performs only the fast
 * repair path.
 */
public final class RepairGateActivity extends Activity {
    private static final String MIGRATION_KEY = "boot_recovery_v123_done";

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
                    .putString("setup_stage", "검증된 v1.2.20 부팅 경로 자동 복구")
                    .apply();
        }

        Intent next = new Intent(this, LauncherActivity.class);
        next.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        startActivity(next);
        finish();
    }
}
