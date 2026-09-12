package com.kkomaprogrammer.desktabchrome;

import android.app.Activity;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.os.IBinder;

public class TermuxResultService extends Service {
    public static final String ACTION_BOOTSTRAP_RESULT =
            "com.kkomaprogrammer.desktabchrome.action.TERMUX_BOOTSTRAP_RESULT";

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || !ACTION_BOOTSTRAP_RESULT.equals(intent.getAction())) {
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        SharedPreferences p = getSharedPreferences("state", Context.MODE_PRIVATE);
        Bundle result = intent.getBundleExtra("result");
        if (result == null) {
            reportFailure(p, "Termux가 결과를 반환했지만 result Bundle이 없습니다. Termux 버전 또는 RUN_COMMAND 연동이 올바르지 않습니다.");
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        int err = result.getInt("err", Activity.RESULT_OK);
        int exitCode = result.getInt("exitCode", Integer.MIN_VALUE);
        String errmsg = clean(result.getString("errmsg"));
        String stderr = clean(result.getString("stderr"));
        String stdout = clean(result.getString("stdout"));

        p.edit()
                .putInt("termux_result_err", err)
                .putInt("termux_result_exit", exitCode)
                .putString("termux_result_stderr", trim(stderr, 1200))
                .putString("termux_result_stdout", trim(stdout, 1200))
                .putString("termux_last_error", trim(errmsg, 1200))
                .apply();

        // Internal Termux errors include permission / allow-external-apps / executable validation failures.
        if (!errmsg.isEmpty() || err != Activity.RESULT_OK) {
            String detail = !errmsg.isEmpty() ? errmsg : ("Termux internal error code " + err);
            reportFailure(p, "Termux가 명령을 거부했습니다: " + detail);
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        // If the shell itself failed and the bootstrap script did not already broadcast a clearer failure,
        // expose stderr instead of leaving the UI stuck.
        if (exitCode != Integer.MIN_VALUE && exitCode != 0 && p.getBoolean("setup_running", false)) {
            String detail = stderr.isEmpty() ? ("exit " + exitCode) : ("exit " + exitCode + " · " + trim(stderr, 800));
            reportFailure(p, "Termux 명령 실행 실패: " + detail);
        }

        stopSelf(startId);
        return START_NOT_STICKY;
    }

    private void reportFailure(SharedPreferences p, String message) {
        p.edit()
                .putBoolean("setup_running", false)
                .putLong("setup_eta_base", 0)
                .putString("setup_stage", message)
                .putString("termux_last_error", message)
                .apply();
        SetupService.updateSetupNotification(this,
                p.getInt("setup_progress", 1), message, 0);
        stopService(new Intent(this, SetupService.class));
    }

    private static String clean(String s) {
        return s == null ? "" : s.trim();
    }

    private static String trim(String s, int max) {
        if (s == null) return "";
        s = s.trim();
        return s.length() <= max ? s : s.substring(0, max) + "…";
    }

    @Override public IBinder onBind(Intent intent) { return null; }
}
